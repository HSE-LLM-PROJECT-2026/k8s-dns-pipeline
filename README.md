# K8s DNS Pipeline

## Описание

Сетевой контур и DNS/ingress-пайплайн платформы: маршрутизация сервисов, внешняя публикация endpoint, интеграция с Cilium/MetalLB/CoreDNS/ExternalDNS.

## Основные возможности

- deployment service networks и service routes
- scripts для массового rollout/teardown сетевого контура
- манифесты CoreDNS/ExternalDNS/etcd и вспомогательные утилиты

## Структура проекта

- `scripts/` - основной набор deploy/verify/add-service скриптов
- `manifests/` - yaml-манифесты сетевых компонентов
- `cilium-metallb-install/` - отдельный профиль установки
- `Caddyfile` - конфигурация edge-proxy

## Быстрый старт

- полный deployment: `scripts/deploy-all.sh`
- проверка: `scripts/verify.sh`
- откат: `scripts/teardown.sh`
