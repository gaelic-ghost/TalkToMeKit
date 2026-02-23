# TalkToMeKit

TalkToMeKit provides a Swift service + server for speech synthesis with
Qwen3-TTS, using an embedded arm64 CPython runtime staged inside the package.

## Current status

- In-process CPython embedding is implemented and running.
- `TTMService` integrates Qwen3-TTS as a `swift-service-lifecycle` service.
- `TalkToMeServer` exposes `/synthesize` and model status endpoints.
- Bundled runtime auto-discovery is supported via `TTMPythonRuntimeBundle`.

## Project layout

- `Sources/TTMService`: service-level integration (`TTMQwenService`).
- `Sources/TTMPythonBridge`: CPython bridge + `qwen_tts_runner.py`.
- `Sources/TTMPythonRuntimeBundle`: packaged Python runtime resources.
- `Sources/TTMServer`: HTTP server and OpenAPI handlers.
- `scripts/stage_python_runtime.sh`: stage bundled Python runtime + optional Qwen install/model download.

## Prerequisites

- macOS arm64
- Swift 6.2 toolchain
- Python 3.11 available on PATH (for staging script), e.g. `python3.11`

## Stage bundled runtime

Stage runtime only:

```bash
./scripts/stage_python_runtime.sh --python python3.11 --no-install-qwen
```

Stage runtime + install Qwen deps + download model:

```bash
./scripts/stage_python_runtime.sh --python python3.11 --install-qwen
```

Staged location:

- `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current`

Note:

- `Runtime/current` is intentionally git-ignored and not committed.
- Each developer/CI environment should stage it locally with
  `scripts/stage_python_runtime.sh`.

## Run server with bundled runtime

```bash
swift run TalkToMeServer \
  --hostname 127.0.0.1 \
  --port 8091 \
  --python-runtime-root Sources/TTMPythonRuntimeBundle/Resources/Runtime/current \
  --python-version 3.11
```

If no `--python-runtime-root` is provided, the server attempts bundled runtime
auto-discovery from `TTMPythonRuntimeBundle`.

## Quick API smoke test

```bash
curl -sS http://127.0.0.1:8091/health
curl -sS http://127.0.0.1:8091/model/status
curl -sS -o /tmp/tts.wav \
  -H 'content-type: application/json' \
  -d '{"text":"Hello from TalkToMeKit","format":"wav"}' \
  http://127.0.0.1:8091/synthesize
```

## Runtime environment flags

- `TTM_QWEN_SYNTH_TIMEOUT_SECONDS`: synth request timeout (default `120`).
- `TTM_QWEN_LOCAL_MODEL_PATH`: override model path.
- `TTM_QWEN_MODEL_ID`: override default model id.
- `TTM_QWEN_ALLOW_FALLBACK`: allow silent fallback output when model load/synth fails (`1` or `0`).
- `TTM_PYTHON_ENABLE_FINALIZE`: opt-in CPython finalize on shutdown (`1`); disabled by default for runtime stability with native extension threads.

## Build and test

```bash
swift build
swift test
```
