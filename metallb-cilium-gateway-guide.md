# Установка MetalLB + Cilium Gateway API в Kubernetes

## Обзор

Эта инструкция описывает, как выставить сервис наружу в bare-metal Kubernetes-кластере, используя:

- **MetalLB** — выдаёт внешние IP-адреса для сервисов типа `LoadBalancer` (заменяет облачный балансировщик).
- **Cilium Gateway API** — принимает входящий HTTP/HTTPS-трафик и маршрутизирует его к нужным сервисам.

Схема работы: клиент → внешний IP (MetalLB) → Gateway (Cilium) → HTTPRoute → Service → Pod.

---

## Предварительные требования

- Kubernetes-кластер (bare-metal или on-prem).
- Helm v3 установлен на машине, с которой ведётся управление кластером.

**Важно про порядок установки:** CRD для Gateway API нужно ставить **ДО** установки/обновления Cilium. Если поставить Cilium раньше — агенты не увидят Gateway API и будут его игнорировать.

**Важно про версии:** Cilium 1.18.0 имеет баг с Gateway API на свежих версиях Kubernetes (1.35+). Используйте **1.18.8** или новее. Всегда фиксируйте `--version` при установке через Helm.

---

## Шаг 0. Установка CRD для Gateway API

Kubernetes из коробки не знает, что такое `Gateway`, `HTTPRoute` и т.д. — нужно установить CRD (Custom Resource Definitions). Без них `kubectl apply` на манифесты Gateway API упадёт с ошибкой `no matches for kind "Gateway"`.

Cilium использует experimental-фичи Gateway API, поэтому ставим **experimental** канал:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
```

Флаг `--server-side` нужен, потому что experimental CRD могут быть слишком большими для обычного `kubectl apply`.

Проверка:

```bash
kubectl get crd | grep gateway
```

Должны появиться: `gatewayclasses`, `gateways`, `httproutes`, `referencegrants`, а также experimental-ресурсы (`tcproutes`, `tlsroutes` и др.).

---

## Шаг 1. Установка Cilium с Gateway API

Cilium устанавливается как CNI с включённым Gateway API. **Этот шаг делается ПОСЛЕ установки CRD (шаг 0).**

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.18.8 \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.enableAlpn=true \
  --set gatewayAPI.enableAppProtocol=true
```

**Пояснения к параметрам:**
- `kubeProxyReplacement=true` — Cilium полностью заменяет kube-proxy (для Talos Linux).
- `k8sServiceHost=localhost`, `k8sServicePort=7445` — настройка для Talos Linux (API-сервер через localhost proxy).
- `cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup` — для Talos Linux, где cgroup уже смонтирован.
- `gatewayAPI.enabled=true` — включает Gateway API контроллер в агентах Cilium.

**Если Cilium уже установлен** и нужно включить Gateway API или обновить версию:

```bash
helm upgrade cilium cilium/cilium \
  --version 1.18.8 \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.enableAlpn=true \
  --set gatewayAPI.enableAppProtocol=true
```

**Не используйте `--reuse-values`** — при смене версии чарта могут появиться новые обязательные поля и upgrade упадёт. Всегда указывайте все значения явно.

### Проверка

```bash
kubectl rollout status daemonset/cilium -n kube-system

# GatewayClass должен появиться автоматически со статусом Accepted: True
kubectl get gatewayclass
```

Ожидаемый вывод:
```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       30s
```

---

## Шаг 2. Создание namespace для MetalLB

MetalLB speaker-поды требуют привилегированного доступа к сети (ARP, NDP). Поэтому namespace создаётся с соответствующими Pod Security Standards.

```yaml
# 01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    kubernetes.io/metadata.name: metallb-system
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

**Зачем эти лейблы:** начиная с Kubernetes 1.25 Pod Security Admission включён по умолчанию. Без лейбла `enforce: privileged` speaker-поды не смогут стартовать, потому что им нужны `hostNetwork`, привилегированные capabilities и т.д.

```bash
kubectl apply -f 01-namespace.yaml
```

---

## Шаг 3. Установка MetalLB через Helm

```bash
# Добавляем Helm-репозиторий MetalLB
helm repo add metallb https://metallb.github.io/metallb
helm repo update

# Устанавливаем MetalLB в подготовленный namespace
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --set speaker.ignoreExcludeLB=true
```

**Параметр `speaker.ignoreExcludeLB=true`:** по умолчанию MetalLB speaker игнорирует ноды с лейблом `node.kubernetes.io/exclude-from-external-load-balancers`. Этот флаг отключает такое поведение — speaker будет работать на всех нодах, включая control-plane (полезно в домашних/лабораторных кластерах, где мастер тоже участвует в сети).

### Проверка

Дождитесь, пока все поды запустятся:

```bash
kubectl get all -n metallb-system
```

Должны появиться:
- `deployment.apps/metallb-controller` — 1 под, управляет выделением IP.
- `daemonset.apps/metallb-speaker` — по одному поду на каждую ноду, отвечает на ARP-запросы.

Все поды должны быть в статусе `Running`.

---

## Шаг 4. Настройка пула IP-адресов

MetalLB нужно указать, какие IP-адреса он может раздавать сервисам. Создаём ресурс `IPAddressPool`.

```yaml
# 02-ip-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.42.1.10-10.42.1.100
```

**Как выбрать диапазон адресов:**
- Адреса должны быть из той же подсети, что и ноды кластера (чтобы L2 ARP работал).
- Диапазон не должен пересекаться с DHCP-пулом вашего роутера.
- Не должен пересекаться с уже занятыми статическими IP в сети.
- Пример: если ваши ноды имеют адреса `10.42.1.1–10.42.1.9`, то пул `10.42.1.10–10.42.1.100` — подходящий выбор.

```bash
kubectl apply -f 02-ip-pool.yaml
```

---

## Шаг 5. Включение L2-анонсирования

Чтобы MetalLB начал отвечать на ARP-запросы для адресов из пула, нужен ресурс `L2Advertisement`.

```yaml
# 03-l2-advertisement.yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
```

**Как это работает:** в режиме Layer 2 один из speaker-подов «захватывает» выделенный IP — начинает отвечать на ARP-запросы от имени этого адреса. Весь трафик на этот IP идёт на ноду с этим speaker, а дальше kube-proxy (или Cilium) распределяет трафик по подам.

**Ограничение L2-режима:** весь трафик для конкретного IP идёт через одну ноду (нет балансировки на сетевом уровне). Для домашних и лабораторных сетапов это нормально. Для продакшена с высокими нагрузками стоит рассмотреть BGP-режим.

Если `spec` не указан (или пуст), advertisement привязывается ко **всем** пулам в namespace.

```bash
kubectl apply -f 03-l2-advertisement.yaml
```

---

## Шаг 6. Namespace приложения

Все сервисы живут в namespace `hse-llm-project`. Если он ещё не создан:

```yaml
# 04-app-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hse-llm-project
```

```bash
kubectl apply -f 04-app-namespace.yaml
```

---

## Шаг 7. Деплой тестового приложения

Для примера развернём простое приложение и Service к нему.

```yaml
# 05-app-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app-2-api
  namespace: hse-llm-project
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-app-2-api
  template:
    metadata:
      labels:
        app: test-app-2-api
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:0.2.3   # замените на свой образ
          args:
            - "-text=hello from test-app-2"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: test-app-2-api    # это имя используется в HTTPRoute
  namespace: hse-llm-project
spec:
  selector:
    app: test-app-2-api
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
```

```bash
kubectl apply -f 05-app-deployment.yaml
```

---

## Шаг 8. Создание Gateway

Gateway — это точка входа для внешнего трафика. Cilium создаст под ним Service типа `LoadBalancer`, а MetalLB выдаст ему внешний IP из пула.

```yaml
# 06-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: hse-llm-project
spec:
  gatewayClassName: cilium    # Cilium выступает реализацией Gateway API
  listeners:
    - name: http
      protocol: HTTP
      port: 80
```

**Что происходит после apply:**
1. Cilium видит новый Gateway с `gatewayClassName: cilium`.
2. Создаёт Service типа `LoadBalancer` (имя будет вида `cilium-gateway-<имя-gateway>`).
3. MetalLB видит новый LoadBalancer-сервис и выделяет ему IP из `home-pool`.
4. Speaker начинает анонсировать этот IP по ARP.

```bash
kubectl apply -f 06-gateway.yaml
```

### Проверка

```bash
# Смотрим, что Gateway получил адрес и статус Programmed: True
kubectl get gateway -n hse-llm-project

# Смотрим созданный LoadBalancer-сервис
kubectl get svc -n hse-llm-project
```

В колонке `ADDRESS` у Gateway и `EXTERNAL-IP` у сервиса должен появиться адрес из вашего пула (например, `10.42.1.10`).

---

## Шаг 9. Создание HTTPRoute

HTTPRoute связывает входящие запросы с конкретным backend-сервисом.

```yaml
# 07-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-app-2-route
  namespace: hse-llm-project
spec:
  parentRefs:
    - name: web-gateway
      namespace: hse-llm-project       # явная ссылка на namespace Gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: test-app-2-api  # имя Service из шага 7
          port: 8080
          namespace: hse-llm-project
```

**Пояснения:**
- `parentRefs` — привязывает маршрут к конкретному Gateway. Всегда указывайте namespace явно.
- `matches` с `PathPrefix: /` — ловит все запросы. Можно добавить более специфичные правила (например, `/api`, `/health`).
- `backendRefs` — указывает, куда отправлять трафик. Имя должно точно совпадать с именем Service.

```bash
kubectl apply -f 07-httproute.yaml
```

---

## Шаг 10. Проверка

```bash
# 1. Получаем внешний IP Gateway
export GATEWAY_IP=$(kubectl get gateway web-gateway -n hse-llm-project -o jsonpath='{.status.addresses[0].value}')

echo "Gateway IP: $GATEWAY_IP"

# 2. Делаем запрос
curl http://$GATEWAY_IP/
```

Если всё настроено правильно, вы получите ответ от приложения.

---

## Итоговая структура файлов

```
manifests/
├── 01-namespace.yaml           # Namespace metallb-system (privileged)
├── 02-ip-pool.yaml             # IPAddressPool (диапазон IP)
├── 03-l2-advertisement.yaml    # L2Advertisement (включаем ARP)
├── 04-app-namespace.yaml       # Namespace hse-llm-project
├── 05-app-deployment.yaml      # Deployment + Service приложения
├── 06-gateway.yaml             # Gateway (точка входа)
└── 07-httproute.yaml           # HTTPRoute (маршрутизация)
```

Применение всего целиком:

```bash
kubectl apply -f manifests/
```

---

## Troubleshooting

**GatewayClass не появляется или статус `Unknown` / "Waiting for controller":**
- Убедитесь, что CRD установлены **до** Cilium: `kubectl get crd | grep gateway`.
- Используйте **experimental** канал CRD — стандартных может не хватать.
- Проверьте версию Cilium — 1.18.0 не работает с Kubernetes 1.35+, нужна минимум 1.18.8.
- При `helm upgrade` всегда указывайте `--version` и все `--set` параметры явно (не используйте `--reuse-values` при смене версии чарта).
- Если вы создавали GatewayClass вручную через `kubectl apply`, удалите его перед `helm upgrade` — Helm не сможет импортировать ресурс без своих лейблов.
- После обновления CRD или версии Cilium: `kubectl rollout restart daemonset/cilium -n kube-system`.

**Gateway не получает EXTERNAL-IP (висит `<pending>`):**
- Проверьте, что speaker-поды запущены: `kubectl get pods -n metallb-system`.
- Проверьте, что IPAddressPool создан: `kubectl get ipaddresspool -n metallb-system`.
- Проверьте, что L2Advertisement создан: `kubectl get l2advertisement -n metallb-system`.
- Убедитесь, что диапазон IP в пуле из той же подсети, что и ноды.

**curl зависает или connection refused:**
- Проверьте статус Gateway: `kubectl get gateway -n hse-llm-project` — должен быть `Programmed: True`.
- Проверьте HTTPRoute: `kubectl get httproute -n hse-llm-project`.
- Проверьте, что поды приложения работают: `kubectl get pods -n hse-llm-project`.
- Проверьте, что порт в Service совпадает с портом в backendRefs.

**Speaker-поды не стартуют:**
- Проверьте лейблы namespace: pod-security должен быть `privileged`.
- Логи: `kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker`.

**Полезные команды для диагностики:**
```bash
# Статус Cilium-агента
kubectl exec -n kube-system ds/cilium -- cilium-dbg status --verbose

# Конфигурация Cilium (должен быть enable-gateway-api: true)
kubectl get configmap cilium-config -n kube-system -o yaml | grep -i gateway

# Логи агента
kubectl logs -n kube-system -l k8s-app=cilium --tail=200 | grep -iE "gateway|error"

# Логи оператора
kubectl logs -n kube-system deployment/cilium-operator --tail=100 | grep -iE "gateway|error"
```
