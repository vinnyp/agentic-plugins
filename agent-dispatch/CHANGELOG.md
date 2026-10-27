# Changelog

## [1.9.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.5...agent-dispatch-v1.9.0) (2026-10-27)


### Features

* **agent-dispatch:** attribute mutation catches with expected text and a knock-out ([#68](https://github.com/vinnyp/agentic-plugins/issues/68)) ([c854fc2](https://github.com/vinnyp/agentic-plugins/commit/c854fc2149b2d116bbe410ed33d317e1d2390753))
* **agent-dispatch:** parallel mutation sweeps and a measurement design round ([#73](https://github.com/vinnyp/agentic-plugins/issues/73)) ([0b68fdb](https://github.com/vinnyp/agentic-plugins/commit/0b68fdbf053b0a97f8a30bf89fd50336932320c3))
* **agent-dispatch:** run test suites in parallel with fail-closed accounting ([d82f103](https://github.com/vinnyp/agentic-plugins/commit/d82f103ef20f6fbd3c6c07ded2a9d95bd1bfae44))


### Bug Fixes

* **agent-dispatch:** repo-state test flake, credential redaction and drift-gate hardening ([#71](https://github.com/vinnyp/agentic-plugins/issues/71)) ([9f6cf0e](https://github.com/vinnyp/agentic-plugins/commit/9f6cf0e586cafbd5690ec7054c32a4b03a9f000c))
* **agent-dispatch:** stop capture readers leaking when no writer arrives ([#72](https://github.com/vinnyp/agentic-plugins/issues/72)) ([f3cb715](https://github.com/vinnyp/agentic-plugins/commit/f3cb71570a5c21f978dd4a68713c9c5e9fbcda6f))


### Performance Improvements

* **agent-dispatch:** split the dispatch-worker suite and raise the default job cap ([#74](https://github.com/vinnyp/agentic-plugins/issues/74)) ([6240fa0](https://github.com/vinnyp/agentic-plugins/commit/6240fa025b30462925d6c7f75fab77df202ae546))

## [1.8.5](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.4...agent-dispatch-v1.8.5) (2026-10-26)


### Bug Fixes

* **agent-dispatch:** explain a SIGPIPE baseline; bound load generators ([#66](https://github.com/vinnyp/agentic-plugins/issues/66)) ([142b07c](https://github.com/vinnyp/agentic-plugins/commit/142b07c45fc2f579d7ca0c8ddf727d5c4fa15419))

## [1.8.4](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.3...agent-dispatch-v1.8.4) (2026-10-24)


### Bug Fixes

* **agent-dispatch:** exempt mutation suites from the marker guard, visibly ([#62](https://github.com/vinnyp/agentic-plugins/issues/62)) ([462fb02](https://github.com/vinnyp/agentic-plugins/commit/462fb026a05061f2a83d36605d6f8e5713856262))
* **agent-dispatch:** keep agy review timeouts cross-model via a codex re-run ([#64](https://github.com/vinnyp/agentic-plugins/issues/64)) ([12d4392](https://github.com/vinnyp/agentic-plugins/commit/12d4392dd186cec9b9a1897587d2bf7e99345f5f))
* **agent-dispatch:** refresh a restored file's mtime past the mutant's second ([#61](https://github.com/vinnyp/agentic-plugins/issues/61)) ([cbd069d](https://github.com/vinnyp/agentic-plugins/commit/cbd069d4da5c4183e01cc9c8cff8996333fe684f))
* **agent-dispatch:** send the plan preamble with every build-phase task ([#63](https://github.com/vinnyp/agentic-plugins/issues/63)) ([4e18baf](https://github.com/vinnyp/agentic-plugins/commit/4e18baf908169aed64e7c9e77fae76be4ed31da0))

## [1.8.3](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.2...agent-dispatch-v1.8.3) (2026-10-21)


### Bug Fixes

* **agent-dispatch:** lower-case the build-phase task commit subject ([#59](https://github.com/vinnyp/agentic-plugins/issues/59)) ([cbd247f](https://github.com/vinnyp/agentic-plugins/commit/cbd247fb1c49c72de20a5f1870d3cce17790655c))

## [1.8.2](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.1...agent-dispatch-v1.8.2) (2026-10-20)


### Bug Fixes

* **agent-dispatch:** isolate review workspaces in a private clone and fail on source-repo drift ([#57](https://github.com/vinnyp/agentic-plugins/issues/57)) ([cd59347](https://github.com/vinnyp/agentic-plugins/commit/cd59347b11257fb1c54ebfac0feaef4b9385fb03))

## [1.8.1](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.8.0...agent-dispatch-v1.8.1) (2026-10-19)


### Bug Fixes

* **agent-dispatch:** distinct verdict when the agent is at capacity ([#53](https://github.com/vinnyp/agentic-plugins/issues/53)) ([c8bf416](https://github.com/vinnyp/agentic-plugins/commit/c8bf416c4d5db84e8e91cb3f075da275b6036056))

## [1.8.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.7.3...agent-dispatch-v1.8.0) (2026-10-19)


### Features

* **agent-dispatch:** role-based agy model defaults + codex exec probe in preflight ([#50](https://github.com/vinnyp/agentic-plugins/issues/50)) ([1bb04a5](https://github.com/vinnyp/agentic-plugins/commit/1bb04a5ab9b944ea9edf6d062a17b7a562292af2))

## [1.7.3](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.7.2...agent-dispatch-v1.7.3) (2026-10-10)


### Bug Fixes

* **agent-dispatch:** verify where the peer-review log landed, never assume it ([#46](https://github.com/vinnyp/agentic-plugins/issues/46)) ([d5102ae](https://github.com/vinnyp/agentic-plugins/commit/d5102ae229edf6e49c1175d7c6a1633ce035898d))

## [1.7.2](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.7.1...agent-dispatch-v1.7.2) (2026-10-10)


### Bug Fixes

* **agent-dispatch:** make drive-cold-session fail loudly instead of returning a cut transcript ([#43](https://github.com/vinnyp/agentic-plugins/issues/43)) ([45988ca](https://github.com/vinnyp/agentic-plugins/commit/45988ca280d500e47e9d0eba338f71eadd87ca31))
* **agent-dispatch:** wait for codex stderr capture before limit/auth detection ([#45](https://github.com/vinnyp/agentic-plugins/issues/45)) ([71c5711](https://github.com/vinnyp/agentic-plugins/commit/71c571167cf7e30a7ef0d045f201a19452a4b69e))

## [1.7.1](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.7.0...agent-dispatch-v1.7.1) (2026-09-26)


### Bug Fixes

* **agent-dispatch:** default agy model to Gemini 3.8 Flash (Medium) ([#41](https://github.com/vinnyp/agentic-plugins/issues/41)) ([dd73c9a](https://github.com/vinnyp/agentic-plugins/commit/dd73c9a8f9516894d9aebb34cd45634d023e973a))

## [1.7.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.6.1...agent-dispatch-v1.7.0) (2026-09-21)


### Features

* **running-the-peer-review-gate:** name both requirements-mode callers ([#36](https://github.com/vinnyp/agentic-plugins/issues/36)) ([8905b74](https://github.com/vinnyp/agentic-plugins/commit/8905b7494ccc1bec5112a2656709f85ad7980c08))
* **peer-review-tiers:** the PRD tier's test-lens carve-out names both PRD skills instead of dropping the lens for a document not authored with `writing-prds`, and `peer-interface-reviewer` joins the tier for an agent-format PRD ([#36](https://github.com/vinnyp/agentic-plugins/issues/36)) ([8905b74](https://github.com/vinnyp/agentic-plugins/commit/8905b7494ccc1bec5112a2656709f85ad7980c08))

## [1.6.1](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.6.0...agent-dispatch-v1.6.1) (2026-09-09)


### Bug Fixes

* **agent-dispatch:** accept per-row verdicts as review evidence ([f39604a](https://github.com/vinnyp/agentic-plugins/commit/f39604a7c6fa056596e5f8f1e8644357fa8d240b))

## [1.6.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.5.0...agent-dispatch-v1.6.0) (2026-09-06)


### Features

* add the writing-prds skill and the review-gate requirements mode ([7f19808](https://github.com/vinnyp/agentic-plugins/commit/7f19808d4e82b00d6ed28a810ed2b27cb3b53003))

## [1.5.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.4.0...agent-dispatch-v1.5.0) (2026-09-05)


### Features

* add the staff-software-engineer / peer-staff-software-engineer-reviewer operator+reviewer pair ([#21](https://github.com/vinnyp/agentic-plugins/issues/21)) ([54f3d83](https://github.com/vinnyp/agentic-plugins/commit/54f3d83c210346f4878921feebe598acc6cf5683))


### Bug Fixes

* **agent-dispatch:** reach installed agy personas safely; actually run the test suite ([#20](https://github.com/vinnyp/agentic-plugins/issues/20)) ([243c3ed](https://github.com/vinnyp/agentic-plugins/commit/243c3edb9506154b1b7d381ba27934e4e87ea97a))

## [1.4.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.3.0...agent-dispatch-v1.4.0) (2026-08-31)


### Features

* **peer-reviewer-agents:** add the peer-apps-script-reviewer lens ([#14](https://github.com/vinnyp/agentic-plugins/issues/14)) ([af05cfc](https://github.com/vinnyp/agentic-plugins/commit/af05cfcc64b58fea703f6bc8c510387a083d9217))

## [1.3.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.2.0...agent-dispatch-v1.3.0) (2026-08-31)


### Features

* dual-runtime agent frontmatter for Antigravity (agy) support ([#10](https://github.com/vinnyp/agentic-plugins/issues/10)) ([8226cd3](https://github.com/vinnyp/agentic-plugins/commit/8226cd36f8e9231751c19c2421527ee5c5c0b961))

## [1.2.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.1.0...agent-dispatch-v1.2.0) (2026-08-31)


### Features

* **agent-dispatch:** add three agent-dev-workflow skills ([#8](https://github.com/vinnyp/agentic-plugins/issues/8)) ([3c52790](https://github.com/vinnyp/agentic-plugins/commit/3c52790c56a02d7868ecdab9ebc5c506c997c13f))

## [1.1.0](https://github.com/vinnyp/agentic-plugins/compare/agent-dispatch-v1.0.0...agent-dispatch-v1.1.0) (2026-08-31)


### Features

* **agent-dispatch:** add the peer-review gate (skill + review-gate CLI) ([#6](https://github.com/vinnyp/agentic-plugins/issues/6)) ([d21408d](https://github.com/vinnyp/agentic-plugins/commit/d21408dff600243693ae211d546c08d4cd7da57c))

## 1.0.0

- Initial public release of `agent-dispatch`.
- Published the bare-PATH dispatch CLIs (`coding-preflight.sh`, `coding-dispatch.sh`,
  `coding-build-phase.sh`, `dispatch-worker`, `agent-dispatch-doctor`, and the
  `drive-*-session.sh` scripts) plus the `driving-agent-sessions` skill.
