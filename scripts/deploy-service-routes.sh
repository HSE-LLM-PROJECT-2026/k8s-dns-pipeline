#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

kubectl apply -f "$ROOT_DIR/auto-set-domain-name/06-httproute-security-audit.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/07-referencegrant-grafana.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/08-httproute-grafana.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/09-httproute-frontend.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/10-httproute-deployment-service.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/11-httproute-status-frontend.yaml"
kubectl apply -f "$ROOT_DIR/auto-set-domain-name/13-httproute-postgresql-ui.yaml"

echo "Applied service routes (06..11 + 13)"
