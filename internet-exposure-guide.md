# Вывод внутренних сервисов в интернет через Caddy на VPS

## Обзор

```
Интернет
    ↓ https://frontend.hse-llm-project-2026.ru
VPS (внешний IP, домен указывает сюда)
    ↓ Caddy (автоматический HTTPS + реверс-прокси)
    ↓ переписывает Host: frontend.hse-llm-project-2026.ru → frontend.hse-llm.internal
    ↓ через WireGuard VPN
Кластер: Gateway (10.42.1.10)
    ↓ HTTPRoute (hostname: frontend.hse-llm.internal)
    ↓ Service → Pod
```

Плюс этой схемы: HTTPRoute не нужно менять. Ты прописываешь `hostnames: ["app.hse-llm.internal"]` — и оно работает и внутри VPN, и из интернета через `app.hse-llm-project-2026.ru`.

---

## Шаг 1. Wildcard DNS-запись у reg.ru

В панели reg.ru → Управление доменом → DNS-записи, добавь:

```
Тип: A
Хост: *
Значение: <внешний IP VPS>
TTL: 3600
```

И для корня тоже:

```
Тип: A
Хост: @
Значение: <внешний IP VPS>
TTL: 3600
```

Проверка (подожди 5–10 минут на обновление DNS):

```bash
dig test123.hse-llm-project-2026.ru +short
# Должен вернуть внешний IP VPS
```

---

## Шаг 2. Убедиться, что VPS видит кластер через WireGuard

```bash
# С VPS
ping 10.42.1.10
curl http://10.42.1.10/ -H "Host: testapp.hse-llm.internal"
```

Если curl возвращает ответ от приложения — VPN работает, можно ставить Caddy.

---

## Шаг 3. Установка Caddy на VPS

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

---

## Шаг 4. Настройка Caddy

Caddy будет:
- Принимать HTTPS-запросы на `*.hse-llm-project-2026.ru`.
- Автоматически получать TLS-сертификаты от Let's Encrypt.
- Переписывать Host-заголовок с `<сервис>.hse-llm-project-2026.ru` на `<сервис>.hse-llm.internal`.
- Проксировать запрос на Gateway в кластере (`10.42.1.10`).

```bash
sudo tee /etc/caddy/Caddyfile <<'EOF'
# Глобальные настройки
{
    # on_demand_tls получает сертификат при первом запросе к поддомену
    on_demand_tls {
        # Ограничиваем — выдаём сертификаты только для наших поддоменов
        permission http://localhost:5555/check
    }
}

# Catch-all для всех поддоменов
https://*.hse-llm-project-2026.ru {
    tls {
        on_demand
    }

    # Извлекаем имя сервиса из поддомена и проксируем
    reverse_proxy 10.42.1.10:80 {
        # Переписываем Host: app.hse-llm-project-2026.ru → app.hse-llm.internal
        header_up Host {labels.3}.hse-llm.internal
    }
}

# Корневой домен — редирект или главная страница
https://hse-llm-project-2026.ru {
    respond "HSE LLM platform" 200
}
EOF
```

**Пояснение `{labels.3}`:** Caddy разбивает домен на части. Для `frontend.hse-llm-project-2026.ru`:
- `{labels.0}` = `ru`
- `{labels.1}` = `2026`
- `{labels.2}` = `hse-llm-project`
- `{labels.3}` = `frontend`

Поэтому `{labels.3}.hse-llm.internal` = `frontend.hse-llm.internal`.

---

## Шаг 5. Сервис проверки доменов (защита от злоупотреблений)

On-demand TLS запрашивает сертификат для каждого нового поддомена. Чтобы кто-то не заставил Caddy запрашивать тысячи сертификатов, нужен endpoint проверки.

Простой вариант — скрипт, который разрешает только наш домен:

```bash
sudo tee /usr/local/bin/caddy-check-domain.py <<'PYEOF'
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        domain = query.get("domain", [""])[0]

        if domain.endswith(".hse-llm-project-2026.ru"):
            self.send_response(200)
        else:
            self.send_response(403)

        self.end_headers()

    def log_message(self, format, *args):
        pass  # тишина в логах

HTTPServer(("127.0.0.1", 5555), Handler).serve_forever()
PYEOF

sudo chmod +x /usr/local/bin/caddy-check-domain.py
```

Запускаем как systemd-сервис:

```bash
sudo tee /etc/systemd/system/caddy-domain-check.service <<'EOF'
[Unit]
Description=Caddy domain permission checker
Before=caddy.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/caddy-check-domain.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now caddy-domain-check
```

---

## Шаг 6. Запуск Caddy

```bash
# Открой порты 80 и 443 (если есть файрвол)
sudo ufw allow 80/tcp 2>/dev/null
sudo ufw allow 443/tcp 2>/dev/null

# Перезапуск Caddy
sudo systemctl restart caddy
sudo systemctl status caddy
```

---

## Шаг 7. Проверка

```bash
# С любого компьютера из интернета
curl https://testapp.hse-llm-project-2026.ru/
```

Ожидаемый результат: ответ от приложения (`hello from test-app-2`) + валидный HTTPS-сертификат.

---

## Как это работает целиком

1. Ты создаёшь HTTPRoute с `hostnames: ["myapp.hse-llm.internal"]`.
2. ExternalDNS создаёт DNS-запись для VPN: `myapp.hse-llm.internal → 10.42.1.10`.
3. Из **VPN**: `curl http://myapp.hse-llm.internal/` → работает.
4. Из **интернета**: `curl https://myapp.hse-llm-project-2026.ru/` → Caddy на VPS → переписывает Host → проксирует на 10.42.1.10 → работает.

Никаких дополнительных настроек при добавлении новых сервисов не нужно — и VPN, и интернет подхватывают автоматически.

---

## Troubleshooting

**Caddy не стартует:**
- Логи: `sudo journalctl -u caddy --tail=50`
- Проверь, что порт 80 и 443 не заняты: `sudo ss -lntp | grep -E ':80|:443'`

**Сертификат не выдаётся:**
- Проверь, что caddy-domain-check работает: `curl http://localhost:5555/check?domain=test.hse-llm-project-2026.ru` — должен вернуть 200.
- Проверь, что DNS wildcard настроен: `dig test.hse-llm-project-2026.ru` — должен вернуть IP VPS.
- Проверь, что порт 80 доступен из интернета (Let's Encrypt делает HTTP-01 challenge).

**502 Bad Gateway:**
- Caddy не может достучаться до 10.42.1.10. Проверь WireGuard: `ping 10.42.1.10` с VPS.
- Проверь, что маска подсети позволяет доступ к `10.42.1.x`.

**Host-заголовок переписывается неправильно:**
- Проверь через логи: `curl -v https://myapp.hse-llm-project-2026.ru/ 2>&1 | head -30`.
- На Gateway: `kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=20`.
- Если имя поддомена в `{labels.3}` не совпадает — посчитай labels для своего домена.
