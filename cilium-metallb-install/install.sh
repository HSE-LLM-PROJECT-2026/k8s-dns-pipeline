#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PIPELINE_ROOT}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

INSTALL_GATEWAY_CRDS="${INSTALL_GATEWAY_CRDS:-true}"
GATEWAY_API_CRD_URL="${GATEWAY_API_CRD_URL:-https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml}"

CILIUM_RELEASE="${CILIUM_RELEASE:-cilium}"
CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.8}"

METALLB_RELEASE="${METALLB_RELEASE:-metallb}"
METALLB_NAMESPACE="${METALLB_NAMESPACE:-metallb-system}"
METALLB_SPEAKER_IGNORE_EXCLUDE_LB="${METALLB_SPEAKER_IGNORE_EXCLUDE_LB:-true}"

APPLY_DEMO_STACK="${APPLY_DEMO_STACK:-false}"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

step() {
  echo -e "${YELLOW}== $* ==${NC}"
}

ok() {
  echo -e "${GREEN}[OK]${NC} $*"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "command not found: $1"
    exit 1
  }
}

wait_gatewayclass() {
  local timeout_seconds=240
  local elapsed=0

  step "Wait for GatewayClass cilium"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    if kubectl get gatewayclass cilium >/dev/null 2>&1; then
      ok "GatewayClass cilium exists"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "GatewayClass cilium was not created in ${timeout_seconds}s"
  return 1
}

wait_deploy_rollout() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-300s}"
  step "Rollout deployment/${deployment} in namespace ${namespace}"
  kubectl -n "${namespace}" rollout status "deployment/${deployment}" --timeout="${timeout}"
  ok "deployment/${deployment} is ready"
}

wait_ds_rollout() {
  local namespace="$1"
  local daemonset="$2"
  local timeout="${3:-300s}"
  step "Rollout daemonset/${daemonset} in namespace ${namespace}"
  kubectl -n "${namespace}" rollout status "daemonset/${daemonset}" --timeout="${timeout}"
  ok "daemonset/${daemonset} is ready"
}

install_gateway_crds() {
  if [[ "${INSTALL_GATEWAY_CRDS}" != "true" ]]; then
    step "Skip Gateway API CRD install (INSTALL_GATEWAY_CRDS=${INSTALL_GATEWAY_CRDS})"
    return 0
  fi

  step "Install Gateway API experimental CRDs"
  kubectl apply --server-side -f "${GATEWAY_API_CRD_URL}"
  ok "Gateway API CRDs applied"
}

install_cilium() {
  step "Install/upgrade Cilium ${CILIUM_VERSION}"

  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install "${CILIUM_RELEASE}" cilium/cilium \
    --namespace "${CILIUM_NAMESPACE}" \
    --version "${CILIUM_VERSION}" \
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

  wait_ds_rollout "${CILIUM_NAMESPACE}" cilium 600s

  local operator_deployment=""
  operator_deployment="$(kubectl -n "${CILIUM_NAMESPACE}" get deploy -l k8s-app=cilium-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${operator_deployment}" ]]; then
    operator_deployment="$(kubectl -n "${CILIUM_NAMESPACE}" get deploy -l app.kubernetes.io/name=cilium-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi

  if [[ -n "${operator_deployment}" ]]; then
    wait_deploy_rollout "${CILIUM_NAMESPACE}" "${operator_deployment}" 600s
  fi

  if command -v cilium >/dev/null 2>&1; then
    step "Wait Cilium via cilium status --wait"
    cilium status --wait
    ok "cilium status is OK"
  else
    step "cilium CLI is not installed locally, skip cilium status --wait"
  fi

  wait_gatewayclass
}

install_metallb() {
  step "Apply MetalLB namespace security labels"
  kubectl apply -f "${SCRIPT_DIR}/01-namespace.yaml"

  step "Install/upgrade MetalLB"
  helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install "${METALLB_RELEASE}" metallb/metallb \
    --namespace "${METALLB_NAMESPACE}" \
    --create-namespace \
    --set speaker.ignoreExcludeLB="${METALLB_SPEAKER_IGNORE_EXCLUDE_LB}"

  wait_deploy_rollout "${METALLB_NAMESPACE}" "${METALLB_RELEASE}-controller" 300s
  wait_ds_rollout "${METALLB_NAMESPACE}" "${METALLB_RELEASE}-speaker" 300s

  step "Apply MetalLB IP pool + L2 advertisement"
  kubectl apply -f "${SCRIPT_DIR}/02-ip-pool.yaml"
  kubectl apply -f "${SCRIPT_DIR}/03-l2-advertisement.yaml"
  ok "MetalLB config applied"
}

apply_demo_stack_if_enabled() {
  if [[ "${APPLY_DEMO_STACK}" != "true" ]]; then
    step "Skip demo app stack (APPLY_DEMO_STACK=${APPLY_DEMO_STACK})"
    return 0
  fi

  step "Apply demo app + gateway + route"
  kubectl apply -f "${SCRIPT_DIR}/04-app-namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/05-app-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/06-gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/07-httproute.yaml"
  ok "Demo stack applied"
}

print_summary() {
  step "Summary"
  kubectl get gatewayclass cilium || true
  kubectl -n "${METALLB_NAMESPACE}" get ipaddresspool,l2advertisement || true
  kubectl -A get svc | grep -E 'LoadBalancer|NAMESPACE' || true

  echo
  echo "Done. Next steps:"
  echo "1) Continue with DNS pipeline: cd ${PIPELINE_ROOT} && INSTALL_CILIUM=false ./scripts/deploy-all.sh"
  echo "2) Add routes for real services via: ./scripts/add-service.sh <service> <port> <namespace>"
}

main() {
  need_cmd kubectl
  need_cmd helm

  install_gateway_crds
  install_cilium
  install_metallb
  apply_demo_stack_if_enabled
  print_summary
}

main "$@"
