# TalkToMeKit Refactor Baseline and Guardrails

This document is the baseline contract for the refactor tickets (`TKT-00` through
`TKT-08`).

## Baseline Date

- 2026-02-28

## Refactor Scope Contract

1. No breaking HTTP API changes for existing endpoints in `openapi.yaml`.
2. No breaking changes to public `TTMService` runtime APIs.
3. No command/flag removals for `ttm-cli`.
4. Existing env var keys remain compatible.

## Explicit Non-Goals

1. No endpoint removals.
2. No model ID schema changes.
3. No runtime/model artifact policy changes (`Runtime/current` remains local-only).
4. No migration away from Swift Testing in current test targets.

## Required Validation Commands

Run these at minimum before closing any ticket:

```bash
swift build
swift test
swift test --filter "TTM API endpoints"
swift test --filter TTMCliTests
```

## Known Build/Test Signals

Observed during baseline runs:

1. `swift-openapi-generator` plugin is invoked during build and leaves generated
   outputs up-to-date.
2. Linker warnings may appear while linking plugin tooling:
   - `building for macOS-11.0, but linking with dylib ... built for newer version 13.0`
3. Default `swift test` passes without staged model prerequisites; opt-in suites
   continue to use their existing environment gates.

## CLI Command Matrix (No-Break)

Core commands that must preserve behavior and option compatibility:

1. `ttm-cli health`
2. `ttm-cli version`
3. `ttm-cli status`
4. `ttm-cli inventory`
5. `ttm-cli adapters`
6. `ttm-cli adapter-status <id>`
7. `ttm-cli load --mode <voice_design|custom_voice|voice_clone> [--model-id ...] [--strict-load]`
8. `ttm-cli unload`
9. `ttm-cli speakers [--model-id ...]`
10. `ttm-cli synthesize --mode <voice-design|custom-voice|voice-clone> ...`
11. `ttm-cli play --mode <voice-design|custom-voice|voice-clone> ...`

## API Regression Matrix (No-Break)

The following endpoint behaviors must remain unchanged unless explicitly approved:

1. Health and version payload shape.
2. Adapter/status availability semantics when runtime is disabled.
3. Model load strict/non-strict behavior and status code conventions (`200`/`202`).
4. Synth endpoint content type and failure mapping (`400`, `503`, `500`).
5. Voice clone base64 validation behavior.

