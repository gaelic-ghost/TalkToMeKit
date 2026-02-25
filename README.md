# TalkToMeKit

TalkToMeKit provides a Swift service + server for speech synthesis with
Qwen3-TTS, using an embedded arm64 CPython runtime staged inside the package.

## Current status

- In-process CPython embedding is implemented and running.
- `TTMService` integrates Qwen3-TTS as a `swift-service-lifecycle` service.
- `TalkToMeServer` exposes `/synthesize/voice-design`, `/synthesize/custom-voice`, `/synthesize/voice-clone`, and model status/load endpoints.
- Bundled runtime auto-discovery is supported via `TTMPythonRuntimeBundle`.

## Project layout

- `Sources/TTMService`: service-level integration (`TTMQwenService`).
- `Sources/TTMService`: service runtime + embedded CPython bridge + `qwen_tts_runner.py`.
- `Sources/TTMPythonRuntimeBundle`: packaged Python runtime resources.
- `Sources/TTMServer`: HTTP server and OpenAPI handlers.
- `scripts/stage_python_runtime.sh`: stage bundled Python runtime + optional Qwen install/model download.

## Prerequisites

- macOS arm64
- Swift 6.2 toolchain
- Python 3.11 available on PATH (for staging script), e.g. `python3.11`

## Stage bundled runtime

Use the SwiftPM command plugin for all normal workflows:

```bash
# Default: incremental staging.
# Stages only missing categories (runtime, site-packages, selected models).
# Default selected models: 0.6B CustomVoice + 0.6B Base (VoiceClone).
swift package plugin --allow-network-connections all stage-python-runtime

# Force uv installer
swift package plugin --allow-network-connections all stage-python-runtime -- -uv

# Full restage (all categories)
swift package plugin --allow-network-connections all stage-python-runtime -- --restage

# Rebuild runtime only (libpython/stdlib/bin tools)
swift package plugin --allow-network-connections all stage-python-runtime -- --restage-runtime

# Reinstall site-packages only
swift package plugin --allow-network-connections all stage-python-runtime -- --restage-packages

# Redownload selected models only
swift package plugin --allow-network-connections all stage-python-runtime -- --restage-models

# Install deps only (skip model downloads)
swift package plugin --allow-network-connections all stage-python-runtime -- --noload

# Also include large 1.7B models
swift package plugin --allow-network-connections all stage-python-runtime -- --bigcv --bigvd --bigvc
```

Direct script usage is still available for local debugging:

```bash
./scripts/stage_python_runtime.sh -uv --noload
```

Dependency pinning:
- Runtime dependencies are specified in `scripts/python-runtime/pyproject.toml`.
- Resolved pins are locked in `scripts/python-runtime/uv.lock`.
- Keep both updated together with a validated set when changing torch/qwen/transformers stack.

Staging behavior:
- Runtime category: `libpython`, stdlib, and bundled `sox` tools.
- Packages category: `site-packages` runtime dependencies.
- Models category: selected model directories under `Runtime/current/models`.
- By default, staging is conditional and only refreshes missing categories.
- `--restage` forces all categories.
- `--restage-runtime`, `--restage-packages`, and `--restage-models` target categories independently.
- `--noload` disables model downloads for the run.

Staged location:

- `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current`

Note:

- `Runtime/current` is intentionally git-ignored and not committed.
- Each developer/CI environment should stage it locally before running server/app code.

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

## CLI client (`ttm-cli`)

`TalkToMeKit` includes a CLI client product for the server API.

```bash
swift run ttm-cli --help
```

Common checks:

```bash
swift run ttm-cli health
swift run ttm-cli version
swift run ttm-cli status
swift run ttm-cli inventory
swift run ttm-cli adapters
swift run ttm-cli adapter-status qwen3-tts
swift run ttm-cli speakers --model-id Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice
```

Model load/unload:

```bash
swift run ttm-cli load --mode custom_voice --model-id Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
swift run ttm-cli load --mode voice_design --strict-load
swift run ttm-cli unload
```

Synthesize to file:

```bash
swift run ttm-cli synthesize --mode voice-design --text "Hello from TalkToMeKit" --output /tmp/ttm-vd.wav
swift run ttm-cli synthesize --mode custom-voice --speaker ryan --text "Hello from TalkToMeKit" --output /tmp/ttm-cv.wav
swift run ttm-cli synthesize --mode voice-clone --reference-audio /path/to/reference.wav --text "Hello from TalkToMeKit" --output /tmp/ttm-vc.wav
```

Play immediately:

```bash
swift run ttm-cli play --mode voice-design --text "Quick playback check"
```

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
swift package plugin --allow-writing-to-package-directory --allow-network-connections all stage-python-runtime -- -uv
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
- The staging script stages `sox` from `static-sox` into `Runtime/current/bin` and does not use host `sox`.
- Prepend `Runtime/current/bin` to `PATH` before `runtime.start()` so `qwen-tts` can find bundled `sox`.

### Runtime request options in app code

Use per-request mode, model, voice/speaker, and language:

```swift
import TTMService

let wav = try await runtime.synthesize(
	.init(
		text: "Hello from app",
		voice: "ryan", // speaker for custom_voice, instruction for voice_design
		instruct: "Cheerful with slightly faster pacing", // optional for custom_voice
		mode: .customVoice, // or .voiceDesign / .voiceClone
		modelID: .customVoice0_6B, // or .customVoice1_7B / .voiceDesign1_7B / .voiceClone0_6B / .voiceClone1_7B
		language: "English"
	)
)
```

Defaults:
- VoiceDesign default model: `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`
- CustomVoice default model: `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`
- VoiceClone default model: `Qwen/Qwen3-TTS-12Hz-0.6B-Base`
- CustomVoice default speaker (when `voice` is omitted): `ryan`

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
  -d '{"text":"Hello from TalkToMeKit","speaker":"ryan","instruct":"Cheerful and energetic","language":"English","format":"wav"}' \
  http://127.0.0.1:8091/synthesize/custom-voice
curl -sS -o /tmp/tts-clone.wav \
  -H 'content-type: application/json' \
  -d '{"text":"Hello from TalkToMeKit","reference_audio_b64":"<BASE64_WAV_BYTES>","language":"English","format":"wav"}' \
  http://127.0.0.1:8091/synthesize/voice-clone
curl -sS \
  -H 'content-type: application/json' \
  -d '{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"}' \
  http://127.0.0.1:8091/model/load
curl -sS \
  -H 'content-type: application/json' \
  -d '{"mode":"voice_design","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","strict_load":true}' \
  http://127.0.0.1:8091/model/load
curl -sS \
  -H 'content-type: application/json' \
  -d '{"mode":"voice_clone","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-Base"}' \
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

### Troubleshooting: `input verification failed` during link

On some toolchain combinations (for example Swift 6.2.3 + Xcode 26.2), `ld`
may print warnings like:

- `warning: input verification failed`
- `note: while processing ... .swift.o`

This is a debug-info verification warning and does not typically indicate a
functional runtime or link failure.

If you want quieter CI/build logs, build with debug info disabled:

```bash
swift build --product TalkToMeServer -Xswiftc -gnone
```

### Troubleshooting: macOS deployment/linker mismatch warnings

You may also see warnings like:

- `ld: warning: building for macOS-11.0, but linking with dylib '/usr/lib/swift/libswiftCore.dylib' which was built for newer version 13.0`

In this package, these are emitted while linking the Swift OpenAPI generator
tool used by the `OpenAPIGenerator` plugin, not while linking `TalkToMeServer`.
The upstream `swift-openapi-generator` package currently declares
`.macOS(.v10_15)`, which can trigger these warnings with newer Xcode/Swift
toolchains.

These warnings are generally benign. If you need quieter CI logs, either:

- keep generated OpenAPI sources checked in and avoid plugin-driven regeneration during routine builds, or
- filter this specific warning line in CI log post-processing.

## Embedding checklist (macOS apps)

When embedding `TalkToMeService` into a macOS app, the following items should be explicitly accounted for:

- Scripts
  - Runtime staging script in this repo: `scripts/stage_python_runtime.sh`
  - App-side copy/sign script in your host app project: `Scripts/stage_python_runtime.sh`
- Build settings (app project)
  - `ENABLE_USER_SCRIPT_SANDBOXING = NO` when app build scripts need sibling checkout access (for example `../TalkToMeKit/...`).
  - `ENABLE_HARDENED_RUNTIME = YES` for production hardening.
  - `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` only if runtime/model download may happen at runtime; disable for offline-only staged deployments.
- Sandbox caveats
  - User script sandbox can block reading runtime assets outside project root.
  - Pre-stage runtime/models in CI or local dev to avoid runtime network dependency.
- Hardened runtime caveats
  - All copied runtime Mach-O artifacts (`.dylib`, `.so`, and executable tools like `sox`) must be signed in the app bundle.
  - Prefer Xcode-provided signing identity values (`EXPANDED_CODE_SIGN_IDENTITY`) over hardcoded identities.

Security note:
- Keep copy/sign scripts secret-free; use Xcode-provided signing identity context at build time.
- Avoid publishing full CI logs that include detailed local code-signing identity metadata unless needed.

## Stability smoke

Run stability smoke as Swift integration tests (mode-switch + cold-start):

```bash
TTM_RUN_STABILITY_SMOKE=1 swift test --filter "TTM stability smoke"
```

Adjust iteration counts:

```bash
TTM_RUN_STABILITY_SMOKE=1 TTM_STABILITY_MIXED_ITERS=10 TTM_STABILITY_COLD_ITERS=4 swift test --filter "TTM stability smoke"
```

Notes:
- These tests are opt-in and skipped unless `TTM_RUN_STABILITY_SMOKE=1`.
- They require a staged runtime at `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current`.

## Backend/dtype matrix tests

Run opt-in backend/dtype integration tests (CPU baseline + invalid backend/dtype behavior):

```bash
TTM_RUN_BACKEND_DTYPE_MATRIX=1 swift test --filter "Backend/dtype matrix"
```

Notes:
- These tests are opt-in and skipped unless `TTM_RUN_BACKEND_DTYPE_MATRIX=1`.
- They require a staged runtime at `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current`.
- They currently require `Qwen3-TTS-12Hz-0.6B-CustomVoice` to be present under staged `models/`.

## Artifact IRL tests

Build the server artifact first:

```bash
swift build -c release --product TTMServer
```

Smoke (artifact startup + health + synth):

```bash
TTM_RUN_ARTIFACT_SMOKE=1 TTM_ARTIFACT_PATH=.build/release/TTMServer swift test --filter ServerArtifactSmokeTests
```

Functional (staging/failure paths + backend/dtype artifact matrix):

```bash
TTM_RUN_ARTIFACT_FUNCTIONAL=1 TTM_ARTIFACT_PATH=.build/release/TTMServer swift test --filter ServerArtifactStagingTests
TTM_RUN_ARTIFACT_FUNCTIONAL=1 TTM_ARTIFACT_PATH=.build/release/TTMServer swift test --filter ServerArtifactBackendDtypeTests
```

Audio quality metrics (objective checks):

```bash
TTM_RUN_ARTIFACT_AUDIO=1 TTM_ARTIFACT_PATH=.build/release/TTMServer swift test --filter ServerArtifactAudioMetricsTests
```

Notes:
- These suites are opt-in and skipped unless their `TTM_RUN_ARTIFACT_*` env var is set.
- Default runtime root is `Sources/TTMPythonRuntimeBundle/Resources/Runtime/current` unless overridden by `TTM_RUNTIME_DIR`.
- Artifact suites require staged runtime assets (including `lib/libpython3.11.dylib`) and the `Qwen3-TTS-12Hz-0.6B-CustomVoice` model.
- Backend/dtype and audio suites can be parameterized with `TTM_TEST_BACKEND` and `TTM_TEST_DTYPE`.
- Set `TTM_ARTIFACT_REQUIRE_PREREQS=1` (or run in CI with `CI=1`) to fail functional/audio suites when runtime/model prerequisites are missing, instead of silently no-oping those tests.
