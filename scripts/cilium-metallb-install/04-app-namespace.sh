#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

kubectl apply -f "$ROOT_DIR/cilium-metallb-install/04-app-namespace.yaml"
echo "Applied cilium-metallb-install/04-app-namespace.yaml"
