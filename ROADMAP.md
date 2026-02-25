# Project Roadmap

## Current Milestone
- ID: M2
- Name: Runtime Staging Reliability Hardening
- Status: In Progress
- Target Version: v0.5.0
- Last Updated: 2026-02-25
- Summary: Core service/server/runtime embedding are implemented and broadly tested, with current work focused on making runtime staging behavior fully deterministic. `swift build` passes; `swift test` currently fails in 2 staging integration cases that gate this milestone.

## Milestones
| ID | Name | Target Version | Status | Target Date | Notes |
| --- | --- | --- | --- | --- | --- |
| M1 | Core Runtime + Server Foundation | v0.4.0 | Completed | 2026-02-24 | Embedded CPython runtime, Qwen-backed service runtime, server endpoints, OpenAPI wiring, and broad integration test scaffolding are in place. |
| M2 | Runtime Staging Reliability Hardening | v0.5.0 | In Progress | 2026-03-06 | Resolve staging-script regressions and stabilize restage semantics for packages/sox handling. |
| M3 | Productization Pass (CLI + CI + Distribution) | v0.6.0 | Planned | 2026-03-27 | Implement `ttm-cli`, tighten CI matrix and prerequisite enforcement, and improve release/operator docs. |

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

## Change Log
- 2026-02-25: Initialized roadmap at repository root as canonical planning record.
- 2026-02-25: Set active milestone to M2 based on current test status (2 staging integration failures) and build health.
