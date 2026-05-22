# Автоматический DNS для Gateway API: CoreDNS + etcd + ExternalDNS

## Обзор

Пайплайн: ты прописываешь `hostnames` в HTTPRoute → ExternalDNS подхватывает → пишет A-запись в etcd → CoreDNS отдаёт DNS-ответ → клиенты в VPN резолвят домен.

```
HTTPRoute (hostnames: ["app.hse-llm.internal"])
    ↓ ExternalDNS следит за HTTPRoute
    ↓ берёт hostname + IP Gateway
    ↓ пишет A-запись в etcd
CoreDNS (авторитативный для hse-llm.internal)
    ↓ читает записи из etcd
    ↓ отвечает на DNS-запросы
VPN-клиенты → dig app.hse-llm.internal → 10.42.1.10
```

Компоненты:
- **etcd** — хранилище DNS-записей.
- **CoreDNS** (отдельный, не кластерный) — DNS-сервер для зоны `hse-llm.internal`.
- **ExternalDNS** — следит за Gateway API ресурсами, автоматически создаёт/удаляет записи.

---

## Шаг 1. Деплой etcd

Простой single-node etcd для хранения DNS-записей. Для DNS-записей это достаточно — потеря данных не критична, ExternalDNS пересоздаст их.

```yaml
# dns-pipeline/01-etcd.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: etcd-dns
  namespace: hse-llm-project
  labels:
    app: etcd-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: etcd-dns
  template:
    metadata:
      labels:
        app: etcd-dns
    spec:
      containers:
        - name: etcd
          image: quay.io/coreos/etcd:v3.5.17
          command:
            - etcd
            - --listen-client-urls=http://0.0.0.0:2379
            - --advertise-client-urls=http://etcd-dns.hse-llm-project.svc.cluster.local:2379
            - --data-dir=/var/lib/etcd
          ports:
            - containerPort: 2379
              name: client
          volumeMounts:
            - name: etcd-data
              mountPath: /var/lib/etcd
      volumes:
        - name: etcd-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: etcd-dns
  namespace: hse-llm-project
spec:
  selector:
    app: etcd-dns
  ports:
    - port: 2379
      targetPort: 2379
      name: client
```

```bash
kubectl apply -f dns-pipeline/01-etcd.yaml
```

---

## Шаг 2. Деплой CoreDNS (внешний, для зоны hse-llm.internal)

Это отдельный CoreDNS (не кластерный kube-dns). Он авторитативный только для зоны `hse-llm.internal` и читает записи из etcd.

```yaml
# dns-pipeline/02-coredns-external.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-external
  namespace: hse-llm-project
data:
  Corefile: |
    hse-llm.internal:53 {
        etcd {
            path /skydns
            endpoint http://etcd-dns.hse-llm-project.svc.cluster.local:2379
        }
        errors
        log
        cache 30
    }
    .:53 {
        forward . /etc/resolv.conf
        errors
        cache 30
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns-external
  namespace: hse-llm-project
  labels:
    app: coredns-external
spec:
  replicas: 2
  selector:
    matchLabels:
      app: coredns-external
  template:
    metadata:
      labels:
        app: coredns-external
    spec:
      containers:
        - name: coredns
          image: coredns/coredns:1.12.0
          args: ["-conf", "/etc/coredns/Corefile"]
          ports:
            - containerPort: 53
              protocol: UDP
              name: dns
            - containerPort: 53
              protocol: TCP
              name: dns-tcp
          volumeMounts:
            - name: config
              mountPath: /etc/coredns
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: coredns-external
---
apiVersion: v1
kind: Service
metadata:
  name: coredns-external
  namespace: hse-llm-project
spec:
  type: LoadBalancer          # MetalLB выдаст внешний IP
  selector:
    app: coredns-external
  ports:
    - port: 53
      targetPort: 53
      protocol: UDP
      name: dns
    - port: 53
      targetPort: 53
      protocol: TCP
      name: dns-tcp
```

**Сервис типа LoadBalancer** — MetalLB выдаст ему IP из пула (например, `10.42.1.11`). На этот IP нужно будет направлять DNS-запросы VPN-клиентов.

```bash
kubectl apply -f dns-pipeline/02-coredns-external.yaml
```

Проверка:

```bash
# Дождись внешнего IP
kubectl get svc coredns-external -n hse-llm-project
```

---

## Шаг 3. Обновление Gateway — wildcard listener

Чтобы Gateway принимал трафик для любого поддомена `*.hse-llm.internal`, обновляем listener:

```yaml
# dns-pipeline/03-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: hse-llm-project
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.hse-llm.internal"
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
kubectl apply -f dns-pipeline/03-gateway.yaml
```

---

## Шаг 4. Деплой ExternalDNS

ExternalDNS следит за Gateway API ресурсами (HTTPRoute, Gateway) и автоматически создаёт DNS-записи в etcd.

```yaml
# dns-pipeline/04-external-dns.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: hse-llm-project
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes", "grpcroutes", "tlsroutes", "tcproutes", "udproutes"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
  - kind: ServiceAccount
    name: external-dns
    namespace: hse-llm-project
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: hse-llm-project
  labels:
    app: external-dns
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
        - name: external-dns
          image: registry.k8s.io/external-dns/external-dns:v0.15.1
          args:
            - --source=gateway-httproute
            - --source=gateway-grpcroute
            - --provider=coredns
            - --domain-filter=hse-llm.internal
            - --policy=upsert-only
            - --registry=txt
            - --txt-owner-id=hse-llm-project
            - --log-level=info
          env:
            - name: ETCD_URLS
              value: "http://etcd-dns.hse-llm-project.svc.cluster.local:2379"
```

**Пояснения к аргументам:**
- `--source=gateway-httproute` — следит за HTTPRoute.
- `--provider=coredns` — пишет записи в etcd (формат CoreDNS /skydns).
- `--domain-filter=hse-llm.internal` — обрабатывает только этот домен.
- `--policy=upsert-only` — только создаёт и обновляет, не удаляет (безопасно для начала; поменяй на `sync` когда убедишься, что работает).

```bash
kubectl apply -f dns-pipeline/04-external-dns.yaml
```

Проверка:

```bash
kubectl logs -n hse-llm-project -l app=external-dns --tail=30
```

---

## Шаг 5. Создание HTTPRoute с hostname

Теперь создаём HTTPRoute — ExternalDNS автоматически подхватит hostname и создаст DNS-запись.

```yaml
# dns-pipeline/05-httproute-example.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-app-2-route
  namespace: hse-llm-project
spec:
  parentRefs:
    - name: web-gateway
      namespace: hse-llm-project
  hostnames:
    - "testapp.hse-llm.internal"    # ← прописываешь руками
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: test-app-2-api
          port: 8080
          namespace: hse-llm-project
```

```bash
kubectl apply -f dns-pipeline/05-httproute-example.yaml
```

ExternalDNS в течение ~1 минуты создаст запись: `testapp.hse-llm.internal → 10.42.1.10`

---

## Шаг 6. Настройка DNS-форвардинга на роутере

Узнай IP, который MetalLB выдал CoreDNS:

```bash
kubectl get svc coredns-external -n hse-llm-project -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Допустим это `10.42.1.11`. Настройка делается **один раз на роутере** (Linux-компе), после чего все клиенты в сети автоматически резолвят `*.hse-llm.internal`.

**Важно про подсеть:** если IP-пул MetalLB (`10.42.1.x`) в другой /24-подсети, чем ноды кластера (`10.42.0.x`), убедитесь, что маска на сетевых интерфейсах — `/16` (или шире), а не `/24`. Иначе трафик до `10.42.1.11` не пройдёт. Проверить на роутере: `ip addr show | grep 10.42`. Если стоит `/24` — поменять:

```bash
sudo ip addr del 10.42.0.1/24 dev enp0s31f6
sudo ip addr add 10.42.0.1/16 dev enp0s31f6
```

Сделайте это изменение постоянным в настройках сети (netplan, NetworkManager и т.д.).

**Если на роутере CoreDNS (наш случай):**

Добавьте блок для зоны `hse-llm.internal` в `/etc/coredns/Corefile`:

```
hse-llm.internal:53 {
    forward . 10.42.1.11
    cache 30
    log
    errors
}

# ... остальные блоки (.:53, cluster.local:53 и т.д.) оставляем как есть
```

```bash
sudo systemctl restart coredns
```

**Если dnsmasq:**

```bash
echo "server=/hse-llm.internal/10.42.1.11" >> /etc/dnsmasq.conf
sudo systemctl restart dnsmasq
```

**Если systemd-resolved:**

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/hse-llm.conf
[Resolve]
DNS=10.42.1.11
Domains=~hse-llm.internal
EOF
sudo systemctl restart systemd-resolved
```

**Если bind9/named:**

```
zone "hse-llm.internal" {
    type forward;
    forwarders { 10.42.1.11; };
};
```

После этого все клиенты, использующие роутер как DNS, автоматически резолвят `*.hse-llm.internal` без каких-либо настроек на их стороне.

---

## Шаг 7. Проверка всего пайплайна

```bash
# 1. CoreDNS получил IP?
COREDNS_IP=$(kubectl get svc coredns-external -n hse-llm-project -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "CoreDNS IP: $COREDNS_IP"

# 2. ExternalDNS создал записи?
kubectl logs -n hse-llm-project -l app=external-dns --tail=20

# 3. DNS резолвит изнутри кластера?
kubectl run tmp-dns --image=curlimages/curl --rm -it --restart=Never -- \
  sh -c "nslookup testapp.hse-llm.internal coredns-external.hse-llm-project.svc.cluster.local"

# 4. DNS резолвит с роутера?
#    (выполнить на роутере)
dig @127.0.0.1 testapp.hse-llm.internal +short

# 5. DNS резолвит с клиента через роутер?
#    (выполнить на клиенте в VPN)
dig testapp.hse-llm.internal +short

# 6. curl по домену
curl http://testapp.hse-llm.internal/
```

Ожидаемый результат на каждом шаге:
```
dig → 10.42.1.10
curl → hello from test-app-2
```

---

## Как добавлять новые сервисы

Для каждого нового сервиса нужно:

1. Создать Deployment + Service (как обычно).
2. Создать HTTPRoute с нужным hostname:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-new-service-route
  namespace: hse-llm-project
spec:
  parentRefs:
    - name: web-gateway
      namespace: hse-llm-project
  hostnames:
    - "myservice.hse-llm.internal"    # ← задаёшь руками
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-new-service
          port: 8080
          namespace: hse-llm-project
```

Через ~1 минуту `myservice.hse-llm.internal` будет резолвиться и работать. Больше ничего делать не нужно.

---

## Итоговая структура файлов

```
dns-pipeline/
├── 01-etcd.yaml                # etcd для хранения DNS-записей
├── 02-coredns-external.yaml    # CoreDNS (авторитативный для зоны)
├── 03-gateway.yaml             # Gateway с wildcard hostname
├── 04-external-dns.yaml        # ExternalDNS (HTTPRoute → etcd)
└── 05-httproute-example.yaml   # Пример HTTPRoute с hostname
```

---

## Troubleshooting

**ExternalDNS не создаёт записи:**
- Логи: `kubectl logs -n hse-llm-project -l app=external-dns --tail=50`
- Проверь, что `hostnames` указан в HTTPRoute (без него ExternalDNS не знает, какую запись создать).
- Проверь `--domain-filter` — hostname должен быть поддоменом.

**dig не резолвит (отвечает неправильным IP):**
- Проверь, что etcd доступен: `kubectl exec -n hse-llm-project deployment/etcd-dns -- etcdctl get /skydns --prefix`
- Проверь логи CoreDNS: `kubectl logs -n hse-llm-project -l app=coredns-external --tail=30`
- Убедись, что Corefile CoreDNS содержит правильный домен (не старый). После изменения ConfigMap нужен рестарт: `kubectl rollout restart deployment/coredns-external -n hse-llm-project`

**dig возвращает `198.18.0.x` или одинаковый ответ на любой IP — DNS-перехват:**
- Это VPN-клиенты (ZeroTier, OpenClaw, Tailscale и т.д.) перехватывают все DNS-запросы.
- Проверь: `sudo ss -lnup | grep :53` и `sudo tcpdump -i any -n port 53` — смотри, через какой интерфейс уходят запросы.
- Если запросы уходят через интерфейс `Meta`, `tailscale0` и т.д. — нужно убрать DNS-перехват в VPN-клиенте или удалить интерфейс: `sudo ip link delete Meta`.
- После удаления перехватчика почисти кеш: `sudo resolvectl flush-caches`.

**Пакеты не доходят до `10.42.1.x` (traceroute зависает):**
- Скорее всего маска подсети `/24`, а пул MetalLB в другой /24. Проверь: `ip addr show | grep 10.42`.
- Если маска `/24` — расширь до `/16`: `sudo ip addr del 10.42.0.1/24 dev <интерфейс> && sudo ip addr add 10.42.0.1/16 dev <интерфейс>`.
- Не забудь сделать это постоянным (netplan, NetworkManager и т.д.).

**curl по домену не работает, но dig отвечает:**
- Проверь, что DNS на клиенте настроен правильно: `resolvectl status`
- Проверь, что Gateway listener принимает этот hostname (wildcard `*.hse-llm.internal`).
- Если Gateway настроен на wildcard, голый IP работать не будет — используй `curl -H "Host: app.hse-llm.internal" http://10.42.1.10/`.

**CoreDNS не получает LoadBalancer IP:**
- Проверь MetalLB: `kubectl get svc coredns-external -n hse-llm-project`
- Пул может быть исчерпан: `kubectl get ipaddresspool -n metallb-system -o yaml`

**Проверка изнутри кластера (если снаружи не работает):**
```bash
kubectl run tmp-dns --image=curlimages/curl --rm -it --restart=Never -- \
  sh -c "nslookup testapp.hse-llm.internal coredns-external.hse-llm-project.svc.cluster.local"
```
Если изнутри работает, а снаружи нет — проблема в сети или DNS-перехвате на клиенте.
