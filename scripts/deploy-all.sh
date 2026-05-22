#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/deploy-cilium-metallb.sh"
"$SCRIPT_DIR/deploy-dns-manifests.sh"
"$SCRIPT_DIR/deploy-service-routes.sh"
