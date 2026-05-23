# Kubernetes DNS Pipeline

[HSE-LLM-PROJECT-2026/k8s-dns-pipeline](https://github.com/HSE-LLM-PROJECT-2026/k8s-dns-pipeline)

## Описание

Репозиторий сетевого слоя платформы: Cilium, MetalLB, Gateway API, external-dns, CoreDNS и HTTPRoute для публичных доменов. Через него сервисы получают нормальные entrypoints наружу.

## Основные возможности

- установка Cilium и MetalLB
- настройка Gateway API
- external-dns и CoreDNS для внутренних/внешних имен
- HTTPRoute для frontend, backend, Grafana, status и других сервисов
- скрипты полного deploy/delete сетевого слоя

## Структура проекта

- `cilium-metallb-install/` — Cilium/MetalLB/Gateway API manifests
- `auto-set-domain-name/` — DNS, Gateway и HTTPRoute manifests
- `scripts/` — deploy/delete/verify скрипты
- `Caddyfile` — вспомогательная конфигурация reverse proxy
- `*-guide.md` — заметки по настройке сети

## Быстрый старт

Полная раскатка:

```bash
cd scripts
./deploy-from-scratch.sh
```

Только service routes:

```bash
cd scripts
./deploy-service-routes.sh
```

Проверка:

```bash
cd scripts
./verify.sh
```

## Важное

Перед запуском нужно проверить IP pool MetalLB и домены в HTTPRoute manifests. Они завязаны на текущую сеть стенда.

## Автор

Igor Malysh
