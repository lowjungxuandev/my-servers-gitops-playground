#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/node/shared.sh
source "$SCRIPT_DIR/shared.sh"

install_prereqs application-node
