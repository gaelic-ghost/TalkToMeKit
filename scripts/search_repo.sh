#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: scripts/search_repo.sh <pattern> [path ...]" >&2
  exit 64
fi

pattern="$1"
shift || true

if [ "$#" -eq 0 ]; then
  set -- .
fi

exec rg \
  --glob '!Sources/TTMPythonRuntimeBundle/Resources/Runtime/current/**' \
  --glob '!**/__pycache__/**' \
  --glob '!.build/**' \
  "$pattern" "$@"
