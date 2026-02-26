#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run bundled-model bridge integration tests in isolated Swift test processes.

Usage:
  scripts/bridge_integrates_isolated.sh [options]

Options:
  --continue-on-failure   Run all cases and report summary (default: fail fast)
  --help                  Show this help

Notes:
  - Each case runs via a separate `swift test --filter ...` invocation.
  - This isolates native CPython/Torch lifecycle per case to reduce cross-test bleed.
USAGE
}

CONTINUE_ON_FAILURE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --continue-on-failure)
      CONTINUE_ON_FAILURE=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

TEST_CASES=(
  "TTMServiceTests.TTMServiceTests/bridgeIntegratesVoiceDesign17BIfAvailable"
  "TTMServiceTests.TTMServiceTests/bridgeIntegratesCustomVoice06BIfAvailable"
  "TTMServiceTests.TTMServiceTests/bridgeIntegratesCustomVoice17BIfAvailable"
)

FAILURES=()

echo "Running bridge integration tests in isolated processes..."

for test_id in "${TEST_CASES[@]}"; do
  echo
  echo "==> $test_id"
  if TTM_RUN_BUNDLED_MODEL_INTEGRATION=1 swift test --filter "$test_id"; then
    echo "PASS: $test_id"
  else
    echo "FAIL: $test_id" >&2
    FAILURES+=("$test_id")
    if [[ "$CONTINUE_ON_FAILURE" -ne 1 ]]; then
      exit 1
    fi
  fi
done

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo
  echo "Isolated bridge integration failures (${#FAILURES[@]}):" >&2
  for test_id in "${FAILURES[@]}"; do
    echo "  - $test_id" >&2
  done
  exit 1
fi

echo
echo "All isolated bridge integration tests passed."
