#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/manifests/01-etcd.sh"
"$SCRIPT_DIR/manifests/02-coredns-external.sh"
"$SCRIPT_DIR/manifests/03-gateway.sh"
"$SCRIPT_DIR/manifests/04-external-dns.sh"

echo "Applied DNS pipeline scripts (01..04)"
