#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run TalkToMeServer stability smoke tests.

Usage:
  scripts/stability_smoke.sh [options]

Options:
  --scenario NAME         Scenario to run: mixed-switch|cold-start-vd|all (default: all)
  --iterations N          Iterations per scenario (default: 20 for mixed-switch, 8 for cold-start-vd)
  --port PORT             Server port (default: 8091)
  --runtime-root PATH     Runtime root (default: Sources/TTMPythonRuntimeBundle/Resources/Runtime/current)
  --python-version VER    Python version flag for server (default: 3.11)
  --server-binary PATH    Server executable command (default: swift run TalkToMeServer)
  --help                  Show this help

Notes:
  - This script starts/stops TalkToMeServer automatically.
  - Outputs are written to /tmp/ttm-stability-*.wav and /tmp/ttm-stability-*.log.
USAGE
}

SCENARIO="all"
ITERATIONS=""
PORT="8091"
RUNTIME_ROOT="Sources/TTMPythonRuntimeBundle/Resources/Runtime/current"
PYTHON_VERSION="3.11"
SERVER_CMD=(swift run TalkToMeServer)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO="$2"
      shift 2
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --runtime-root)
      RUNTIME_ROOT="$2"
      shift 2
      ;;
    --python-version)
      PYTHON_VERSION="$2"
      shift 2
      ;;
    --server-binary)
      IFS=' ' read -r -a SERVER_CMD <<<"$2"
      shift 2
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

if [[ "$SCENARIO" != "all" && "$SCENARIO" != "mixed-switch" && "$SCENARIO" != "cold-start-vd" ]]; then
  echo "Unsupported --scenario: $SCENARIO" >&2
  exit 1
fi

if [[ ! -d "$RUNTIME_ROOT" ]]; then
  echo "Runtime root does not exist: $RUNTIME_ROOT" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

SERVER_PID=""
SERVER_LOG=""

cleanup_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}

start_server() {
  local mode="$1"
  local model_id="$2"

  cleanup_server
  SERVER_LOG="/tmp/ttm-stability-$(date +%s)-${mode}.log"

  "${SERVER_CMD[@]}" \
    --hostname 127.0.0.1 \
    --port "$PORT" \
    --python-runtime-root "$RUNTIME_ROOT" \
    --python-version "$PYTHON_VERSION" \
    --qwen-mode "$mode" \
    --qwen-model-id "$model_id" \
    >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

  local ready=0
  for _ in $(seq 1 120); do
    if curl -sS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.25
  done

  if [[ "$ready" -ne 1 ]]; then
    echo "server failed to become ready (log: $SERVER_LOG)" >&2
    tail -n 60 "$SERVER_LOG" >&2 || true
    cleanup_server
    return 1
  fi

  echo "server ready: mode=$mode model=$model_id log=$SERVER_LOG"
}

http_code() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"

  if [[ -n "$payload" ]]; then
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" -H 'content-type: application/json' -d "$payload" "$url"
  else
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$url"
  fi
}

run_mixed_switch() {
  local iterations="$1"
  local ok=0

  echo "== scenario: mixed-switch (iterations=$iterations) =="
  start_server "voice_design" "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"

  for i in $(seq 1 "$iterations"); do
    local code

    code="$(http_code POST "http://127.0.0.1:${PORT}/model/load" '{"mode":"voice_design","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"}')"
    if [[ "$code" != "200" && "$code" != "202" ]]; then
      echo "iter $i failed: load voice_design code=$code"
      return 1
    fi

    code="$(curl -sS -o "/tmp/ttm-stability-vd-${i}.wav" -w '%{http_code}' -H 'content-type: application/json' \
      -d '{"text":"stability mixed vd '$i'","instruct":"Calm concise announcer","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","format":"wav"}' \
      "http://127.0.0.1:${PORT}/synthesize/voice-design")"
    if [[ "$code" != "200" ]]; then
      echo "iter $i failed: synth voice_design code=$code"
      return 1
    fi

    code="$(http_code POST "http://127.0.0.1:${PORT}/model/load" '{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"}')"
    if [[ "$code" != "200" && "$code" != "202" ]]; then
      echo "iter $i failed: load custom_voice code=$code"
      return 1
    fi

    code="$(curl -sS -o "/tmp/ttm-stability-cv-${i}.wav" -w '%{http_code}' -H 'content-type: application/json' \
      -d '{"text":"stability mixed cv '$i'","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}' \
      "http://127.0.0.1:${PORT}/synthesize/custom-voice")"
    if [[ "$code" != "200" ]]; then
      echo "iter $i failed: synth custom_voice code=$code"
      return 1
    fi

    ok=$((ok + 1))
    echo "iter $i ok"
  done

  echo "scenario mixed-switch passed: ok_iters=$ok"
}

run_cold_start_vd() {
  local iterations="$1"

  echo "== scenario: cold-start-vd (iterations=$iterations) =="

  for i in $(seq 1 "$iterations"); do
    start_server "voice_design" "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"

    local code
    code="$(curl -sS -o "/tmp/ttm-stability-cold-vd-${i}.wav" -w '%{http_code}' -H 'content-type: application/json' \
      -d '{"text":"stability cold vd '$i'","instruct":"Warm concise voice","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","format":"wav"}' \
      "http://127.0.0.1:${PORT}/synthesize/voice-design")"

    sleep 0.5
    local alive=0
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      alive=1
    fi

    if [[ "$code" != "200" || "$alive" -ne 1 ]]; then
      echo "cycle $i failed: synth_code=$code alive=$alive"
      tail -n 80 "$SERVER_LOG" >&2 || true
      return 1
    fi

    echo "cycle $i ok"
    cleanup_server
  done

  echo "scenario cold-start-vd passed"
}

trap cleanup_server EXIT

MIXED_ITERS="${ITERATIONS:-20}"
COLD_ITERS="${ITERATIONS:-8}"

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "mixed-switch" ]]; then
  run_mixed_switch "$MIXED_ITERS"
fi

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "cold-start-vd" ]]; then
  run_cold_start_vd "$COLD_ITERS"
fi

echo "stability smoke complete"
