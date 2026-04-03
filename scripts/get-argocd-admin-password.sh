#!/usr/bin/env bash

set -euo pipefail

docker exec ubuntu-server-1 sh -lc "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'" | base64 --decode
echo
