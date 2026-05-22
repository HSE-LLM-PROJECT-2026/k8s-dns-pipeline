#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/cilium-metallb-install/01-namespace.sh"
"$SCRIPT_DIR/cilium-metallb-install/02-ip-pool.sh"
"$SCRIPT_DIR/cilium-metallb-install/03-l2-advertisement.sh"
"$SCRIPT_DIR/cilium-metallb-install/04-app-namespace.sh"
"$SCRIPT_DIR/cilium-metallb-install/05-app-deployment.sh"
"$SCRIPT_DIR/cilium-metallb-install/06-gateway.sh"
"$SCRIPT_DIR/cilium-metallb-install/07-httproute.sh"

echo "Applied cilium-metallb-install scripts (01..07)"
