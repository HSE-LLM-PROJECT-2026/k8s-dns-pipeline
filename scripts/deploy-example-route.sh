#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/manifests/05-httproute-example.sh"
"$SCRIPT_DIR/manifests/06-demo-exposure.sh"
echo "Applied demo exposure scripts (05..06)"
