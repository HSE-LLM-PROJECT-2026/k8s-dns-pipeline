#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$PROJECT_ROOT/cluster-config/llm_proj_talos/kubeconfig}"

export KUBECONFIG="$KUBECONFIG_PATH"

bash "$PROJECT_ROOT/monitoring-deployment/delete-network.sh"
bash "$PROJECT_ROOT/security-and-audit-serivce/deploy/delete-network.sh"
bash "$PROJECT_ROOT/deployment-service/deploy/delete-network.sh"
bash "$PROJECT_ROOT/frontend/deploy/delete-network.sh"
bash "$PROJECT_ROOT/status-frontend/deploy/delete-network.sh"

echo "Service network routes deleted"
