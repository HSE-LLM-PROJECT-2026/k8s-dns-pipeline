#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$PROJECT_ROOT/cluster-config/llm_proj_talos/kubeconfig}"

export KUBECONFIG="$KUBECONFIG_PATH"

bash "$PROJECT_ROOT/frontend/deploy/deploy-network.sh"
bash "$PROJECT_ROOT/status-frontend/deploy/deploy-network.sh"
bash "$PROJECT_ROOT/deployment-service/deploy/deploy-network.sh"
bash "$PROJECT_ROOT/security-and-audit-serivce/deploy/deploy-network.sh"
bash "$PROJECT_ROOT/monitoring-deployment/deploy-network.sh"

echo "Service network routes deployed"
