# Project Roadmap

## Current Milestone
- ID: M3
- Name: Productization Pass (CLI + CI + Distribution)
- Status: In Progress
- Target Version: v0.7.0
- Last Updated: 2026-03-01
- Summary: Risk-first refactor execution is complete, explicit CI checks for `swift build`, `swift test`, `TTMCliTests`, and `TTMApiTests` are now configured, and beta release `v0.7.0-beta.1` is published for soak.

## Milestones
| ID | Name | Target Version | Status | Target Date | Notes |
| --- | --- | --- | --- | --- | --- |
| M1 | Core Runtime + Server Foundation | v0.4.0 | Completed | 2026-02-24 | Embedded CPython runtime, Qwen-backed service runtime, server endpoints, OpenAPI wiring, and broad integration test scaffolding are in place. |
| M2 | Runtime Staging Reliability Hardening | v0.5.0 | Completed | 2026-03-06 | Resolved staging-script regressions and stabilized Python env isolation for restage/sox behavior in full test runs. |
| M3 | Productization Pass (CLI + CI + Distribution) | v0.7.0 | In Progress | 2026-03-27 | `ttm-cli` is implemented and now has dedicated tests. Current focus is modular decomposition, config centralization, CI enforcement, and beta soak. |

## Ticket Execution Status (2026-02-28)
| Ticket | Title | Status | Notes |
| --- | --- | --- | --- |
| TKT-00 | Baseline Guardrails and Scope Lock | Completed | Baseline contract captured in `docs/refactor-plan.md`. |
| TKT-01 | Docs and Naming Parity Hardening | Completed | README naming and command parity aligned to package products. |
| TKT-02 | Dedicated CLI Test Target | Completed | Added `TTMCliTests` target with parsing/build/transport behavior coverage. |
| TKT-03 | CLI Internal Modularization | Completed | CLI split into focused files with shared synthesis request builder and seams. |
| TKT-04 | Server API Handler Decomposition | Completed | `TTMApi` split into endpoint-family extensions plus shared core helpers. |
| TKT-05 | Python Bridge Decomposition | Completed | Bridge actor, type model, and CPython runtime internals separated into focused files. |
| TKT-06 | Typed Configuration Consolidation | Completed | Typed server/runtime env parsing added with focused tests and env compatibility retained. |
| TKT-07 | Repository Hygiene for Large Local Runtime Artifacts | Completed | Added search hygiene documentation and `scripts/search_repo.sh`. |
| TKT-08 | Roadmap and Milestone Reconciliation | Completed | Milestone/ticket status reconciled in roadmap. |

## M3 Acceptance Gates
1. CI must run `swift build`, full `swift test`, `TTMCliTests`, and `TTMApiTests` on pull requests and `main` pushes.
2. Release tag must follow `vx.x.x` format and be pushed before creating the GitHub release object.
3. Release object for `v0.7.0` should be created as prerelease/beta while integration soak continues.

## Plan History
### 2026-02-25 - Accepted Plan (v0.5.0 / M2)
- Scope:
  - Reconcile staging script behavior with integration test expectations for `--restage` and `--restage-runtime`.
  - Ensure package cleanup and static-sox detection behavior are explicit, deterministic, and covered by tests.
  - Keep existing service/server/model APIs stable while improving staging reliability.
- Acceptance Criteria:
  - `swift build` succeeds without functional regressions.
  - `swift test` passes for `Runtime staging script (integration)` suite, including:
    - `--restage resets all categories while still rebuilding runtime`
    - `fails fast when runtime restage requires static-sox but staged packages are missing it`
  - README and roadmap remain aligned with actual runtime staging behavior.
- Risks/Dependencies:
  - Staging behavior depends on environment toolchain (`python3.11`, `uv`, and package layout) and can vary across host setups.
  - Some integration suites are intentionally opt-in and may hide regressions when env flags/prereqs are absent.

### 2026-02-25 - Stability Follow-up (Bundled Model Integration)
- Scope:
  - Investigate and harden `Bridge integrates ...` model-backed integration tests after repeated native crashes in `swiftpm-testing-helper`.
  - Keep default `swift test` stable while preserving an explicit path to run heavy bundled-model coverage.
  - Add deterministic cleanup in integration helpers so bridge teardown is always attempted even after model/synthesis failures.
- Current Findings:
  - `TTM_RUN_BUNDLED_MODEL_INTEGRATION=1` with `bridgeIntegratesCustomVoice17BIfAvailable` can fail in Python runtime with `RuntimeError: Tensor.item() cannot be called on meta tensors`.
  - `bridgeIntegratesVoiceDesign17BIfAvailable` and `bridgeIntegratesCustomVoice17BIfAvailable` can also terminate the process with `SIGSEGV (11)` during model load/import on `device_map=auto` in `swiftpm-testing-helper`.
  - Crash stacks consistently point at CPython/Torch native paths (`PyEval_AcquireThread`, `pybind11::gil_scoped_acquire`) on queue `TalkToMeKit.TTMPythonBridge.CPython`.
  - This appears to be an upstream/native runtime hazard, not a Swift Testing assertion/configuration issue.
- Next Steps:
  - Keep bundled-model bridge integration tests explicitly opt-in.
  - Keep bundled integration assertions strict (exact model, `strict` load, fallback disabled) so failures are not masked.
  - Run bundled bridge integration tests on deterministic `cpu/float32` for now to avoid known 1.7B auto/MPS crash paths.
  - Keep using isolated execution (`scripts/bridge_integrates_isolated.sh`) for heavy native integration coverage.

### 2026-02-26 - CLI Compliance and Coverage Follow-up
- Scope:
  - Ensure `ttm-cli` behavior and payloads remain fully compliant with the server API surface.
  - Add a dedicated `ttm-cli` test suite covering command parsing, request/response handling, and error mapping.
- Acceptance Criteria:
  - `ttm-cli` command options and API calls are validated against current server endpoints and request schemas. ✅
  - `swift test` includes dedicated CLI tests (not only service/server tests). ✅
  - CLI tests cover success paths and at least key failure modes (invalid args, non-2xx responses, malformed payloads). ✅

### 2026-02-26 - Configuration System Follow-up (`swift-configuration`)
- Scope:
  - Evaluate migration from ad-hoc environment/config parsing to a unified `swift-configuration`-based approach.
  - Introduce typed configuration surfaces for server, runtime bridge, and CLI paths where environment variables are currently interpreted directly.
- Acceptance Criteria:
  - Configuration defaults and required keys are centralized and documented in one place. ✅
  - Environment-derived settings used by server/runtime/tests are validated through typed configuration objects. ✅
  - Core configuration paths have focused unit tests (including invalid/partial configuration cases). ✅

## Change Log
- 2026-02-25: Initialized roadmap at repository root as canonical planning record.
- 2026-02-25: Set active milestone to M2 based on current test status (2 staging integration failures) and build health.
- 2026-02-25: Cleared M2 test gate after hardening `stage_python_runtime.sh` to run Python staging steps with sanitized `PYTHONHOME`/`PYTHONPATH`; full `swift test` now passes.
- 2026-02-25: Added bundled-model integration stability follow-up notes after reproducing CustomVoice 1.7B meta-tensor failure and post-failure `SIGSEGV (11)` in `swiftpm-testing-helper`.
- 2026-02-25: Hardened bundled bridge integration tests to enforce strict non-fallback model loads and deterministic `cpu/float32` backend; isolated bridge integration script now passes all three bridge integration cases.
- 2026-02-26: Added roadmap follow-up items for `ttm-cli` API compliance validation and dedicated CLI test-suite coverage.
- 2026-02-26: Added roadmap follow-up to evaluate and adopt `swift-configuration` for centralized typed configuration management.
- 2026-02-28: Executed ticketed refactor plan (`TKT-00` to `TKT-08`) including CLI/server/bridge decomposition, docs parity hardening, typed env config parsing, and dedicated CLI tests.
- 2026-03-01: Added GitHub Actions CI workflow with explicit `swift build`, `swift test`, `TTMCliTests`, and `TTMApiTests` checks; queued `v0.6.0` beta tagging/release.
- 2026-03-01: Published prerelease object `v0.7.0-beta.1` from tag `v0.7.0`.
