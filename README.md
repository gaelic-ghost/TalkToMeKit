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

Preferred: use the SwiftPM command plugin.

Stage runtime only (safe default):

```bash
swift package plugin stage-python-runtime
```

Stage runtime only with explicit python:

```bash
swift package plugin stage-python-runtime -- --python python3.11 --no-install-qwen
```

Stage runtime + install Qwen deps + download model (network-enabled):

```bash
swift package plugin stage-python-runtime -- --allow-network --install-qwen --python python3.11
```

Direct script usage is still available:

```bash
./scripts/stage_python_runtime.sh --python python3.11 --no-install-qwen
```

Staged location:

- `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current`

Note:

- `Runtime/current` is intentionally git-ignored and not committed.
- Each developer/CI environment should stage it locally with
  `swift package plugin stage-python-runtime`.

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

## Embed in a macOS app

`TalkToMeService` now exposes an app-facing runtime wrapper:

```swift
import Foundation
import TTMService

let runtime = TTMServiceRuntime(
	configuration: .init(
		assetProvider: TTMBundledRuntimeAssetProvider(pythonVersion: "3.11"),
		startupTimeoutSeconds: 60
	)
)

try await runtime.start()
let wav = try await runtime.synthesize(.init(text: "Hello from app"))
await runtime.stop()
```

For app-managed assets, use `TTMLocalRuntimeAssetProvider(runtimeRoot:)` with a
runtime path in app support storage (for example after first-launch download).

First-launch download scaffold:

```swift
import Foundation
import TTMService

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let runtimeRoot = appSupport.appendingPathComponent("TalkToMeKit/Runtime/current", isDirectory: true)

let runtime = TTMServiceRuntime(
	configuration: .firstLaunch(
		runtimeRoot: runtimeRoot,
		pythonVersion: "3.11",
		downloadIfNeeded: { root, version in
			// App-specific download/unpack implementation here.
			// Ensure root contains lib/libpython{version}.dylib and lib/python{version}/...
			_ = (root, version)
		},
		onStateChange: { state in
			print("Asset state:", state)
		}
	)
)
```

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
