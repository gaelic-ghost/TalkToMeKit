# TalkToMeKit

TalkToMeKit provides a Swift service + server for speech synthesis with
Qwen3-TTS, using an embedded arm64 CPython runtime staged inside the package.

## Current status

- In-process CPython embedding is implemented and running.
- `TTMService` integrates Qwen3-TTS as a `swift-service-lifecycle` service.
- `TalkToMeServer` exposes `/synthesize/voice-design`, `/synthesize/custom-voice`, and model status/load endpoints.
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
swift package plugin --allow-network-connections all stage-python-runtime
```

Stage runtime only with explicit python:

```bash
swift package plugin --allow-network-connections all stage-python-runtime -- --python python3.11 --no-install-qwen
```

Stage runtime + install Qwen deps + download model (network-enabled):

```bash
swift package plugin --allow-network-connections all stage-python-runtime -- --allow-network --install-qwen --python python3.11
```

Stage runtime + install Qwen deps using `uv` explicitly:

```bash
swift package plugin --allow-network-connections all stage-python-runtime -- --allow-network --install-qwen --installer uv --python python3.11
```

Restage runtime (wipe existing `Runtime/current`, reinstall deps, and download VD 1.7B + CV 0.6B + CV 1.7B):

```bash
swift package plugin --allow-network-connections all stage-python-runtime -- --restage
```

Direct script usage is still available:

```bash
./scripts/stage_python_runtime.sh --python python3.11 --no-install-qwen
```

Dependency pinning:
- Runtime package versions are pinned in `scripts/requirements-qwen.txt`.
- Keep this file updated with a validated set when changing torch/qwen/transformers stack.

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
  --python-version 3.11 \
  --qwen-mode voice_design \
  --qwen-model-id Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign
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

### Xcode embedding workflow (recommended)

Use this when embedding `TalkToMeService` into a macOS app target.

1. Add local package dependency to your app project:
`<path-to-TalkToMeKit>`
2. Link package product `TalkToMeService` to the app target.
3. Stage runtime once in the package checkout:

```bash
cd <path-to-TalkToMeKit>
swift package plugin --allow-writing-to-package-directory --allow-network-connections all stage-python-runtime -- --allow-network --install-qwen --installer uv --python python3.11
```

4. Add a Run Script build phase to the app target (before app code signing), using:

```sh
set -euo pipefail

PKG_RUNTIME_ROOT="${SRCROOT}/../TalkToMeKit/Sources/TTMPythonRuntimeBundle/Resources/Runtime/current"
DEST_RUNTIME_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Runtime/current"

if [ ! -d "${PKG_RUNTIME_ROOT}" ]; then
  echo "error: staged runtime not found at ${PKG_RUNTIME_ROOT}" >&2
  exit 1
fi

rm -rf "${DEST_RUNTIME_ROOT}"
mkdir -p "${DEST_RUNTIME_ROOT}"
/usr/bin/rsync -a --delete "${PKG_RUNTIME_ROOT}/" "${DEST_RUNTIME_ROOT}/"

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
  SIGN_IDENTITY="-"
fi

/usr/bin/find "${DEST_RUNTIME_ROOT}" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 |
while IFS= read -r -d '' artifact; do
  /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none "${artifact}"
done

# Also sign Mach-O executables under Runtime/current/bin (for bundled sox).
/usr/bin/find "${DEST_RUNTIME_ROOT}/bin" -type f -print0 2>/dev/null |
while IFS= read -r -d '' artifact; do
  if /usr/bin/file -b "${artifact}" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none "${artifact}"
  fi
done
```

5. In app code, use bundle-local runtime path:
`Bundle.main.resourceURL/Runtime/current`

Notes:
- If script phase cannot read sibling directories, set app build setting `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
- `DYLD_*` environment variables are not required for MPS.
- `ENABLE_OUTGOING_NETWORK_CONNECTIONS` is only needed when downloading models/deps at runtime.
- The staging script now installs `static-sox` as fallback and stages `sox` into `Runtime/current/bin` when available.
- Prepend `Runtime/current/bin` to `PATH` before `runtime.start()` so `qwen-tts` can find bundled `sox`.

### Runtime request options in app code

Use per-request mode, model, voice/speaker, and language:

```swift
import TTMService
import TTMPythonBridge

let wav = try await runtime.synthesize(
	.init(
		text: "Hello from app",
		voice: "ryan", // speaker for custom_voice, instruction for voice_design
		mode: .customVoice, // or .voiceDesign
		modelID: .customVoice0_6B, // or .customVoice1_7B / .voiceDesign1_7B
		language: "English"
	)
)
```

Defaults:
- VoiceDesign default model: `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`
- CustomVoice default model: `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`
- CustomVoice default speaker (when `voice` is omitted): `ryan`

### Example app reference

`TalkToMeKitExampleApp` demonstrates the full embedding workflow, including:
- local package linking to `TalkToMeKit`
- runtime staging/copy/sign build phase
- mode/model/language controls in SwiftUI
- `TTMServiceRuntime` local runtime startup and synthesis calls

## Quick API smoke test

```bash
curl -sS http://127.0.0.1:8091/health
curl -sS http://127.0.0.1:8091/model/status
curl -sS http://127.0.0.1:8091/model/inventory
curl -sS http://127.0.0.1:8091/custom-voice/speakers
curl -sS -o /tmp/tts-vd.wav \
  -H 'content-type: application/json' \
  -d '{"text":"Hello from TalkToMeKit","instruct":"Warm narrator voice","language":"English","format":"wav"}' \
  http://127.0.0.1:8091/synthesize/voice-design
curl -sS -o /tmp/tts-cv.wav \
  -H 'content-type: application/json' \
  -d '{"text":"Hello from TalkToMeKit","speaker":"ryan","language":"English","format":"wav"}' \
  http://127.0.0.1:8091/synthesize/custom-voice
curl -sS \
  -H 'content-type: application/json' \
  -d '{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"}' \
  http://127.0.0.1:8091/model/load
curl -sS \
  -H 'content-type: application/json' \
  -d '{"mode":"voice_design","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","strict_load":true}' \
  http://127.0.0.1:8091/model/load
```

## Troubleshooting staged models

- Use `GET /model/inventory` to verify which model directories are present under staged runtime `models/`.
- Use `GET /model/status` to compare requested vs active model:
  - `requested_mode`, `requested_model_id`, and `strict_load` show what was asked for.
  - `fallback_applied` indicates runtime loaded a fallback model.
- Use `POST /model/load` with `"strict_load": true` to fail fast instead of falling back when a requested model is not staged.
- Use `GET /custom-voice/speakers` to inspect available speaker IDs for the active or requested CustomVoice model.
- If inventory is missing entries, restage with:

```bash
swift package plugin --allow-network-connections all stage-python-runtime -- --restage
```

## Runtime environment flags

- `TTM_QWEN_SYNTH_TIMEOUT_SECONDS`: synth request timeout (default `120`).
- `TTM_QWEN_LOCAL_MODEL_PATH`: override model path.
- `TTM_QWEN_MODE`: startup mode fallback (`voice_design` default).
- `TTM_QWEN_ALLOW_CROSS_MODE_FALLBACK`: when enabled (`1`), loader may fall back across known models/modes.
- `TTM_QWEN_DEVICE_MAP`: torch/qwen device map (default `cpu`). On Apple Silicon, set to `mps` for GPU acceleration.
- `TTM_QWEN_TORCH_DTYPE`: torch dtype override (`float32` default, `float16` and `bfloat16` supported by runner).
- `TTM_QWEN_ALLOW_FALLBACK`: allow silent fallback output when model load/synth fails (`1` or `0`).
- `TTM_PYTHON_ENABLE_FINALIZE`: opt-in CPython finalize on shutdown (`1`); disabled by default for runtime stability with native extension threads.

Apple Silicon performance tip:

```bash
export TTM_QWEN_DEVICE_MAP=mps
export TTM_QWEN_TORCH_DTYPE=float16
```

If you encounter Metal/MPS assertion failures during model load or synth in an embedded app, use CPU mode:

```bash
export TTM_QWEN_DEVICE_MAP=cpu
unset TTM_QWEN_TORCH_DTYPE
```

## Build and test

```bash
swift build
swift test
```

## Stability smoke

Run both stability scenarios (mode-switch load test + cold-start VoiceDesign test):

```bash
./scripts/stability_smoke.sh
```

Run one scenario only:

```bash
./scripts/stability_smoke.sh --scenario mixed-switch
./scripts/stability_smoke.sh --scenario cold-start-vd
```
