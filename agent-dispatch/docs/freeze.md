# Freeze

agent-dispatch is frozen from release 1.9.5 while its behaviour is captured as
executable checks ahead of a rewrite. Using it is unaffected. Changing it is restricted.

## What may land

| Type | Allowed changes |
| --- | --- |
| Capture | Tests, goldens, recordings, smoke checks in `test/`; `agent-dispatch-doctor --live`. |
| Hotfix | Compatibility fixes for environment breaks that stop a runtime. |
| Safety | Fixes for confirmed defects that can lose work or report false success. |

A Hotfix may address an agy or codex update changing its invocation or auth text.

## What does not

New features, new flags, hardening, refactors, and changes to a contract in
`docs/commands.md` other than those above may not land.

## Hotfix rules

A hotfix covers compatibility only. It adds a test or smoke check in the same change.
It updates the affected goldens deliberately and says so in the PR. It is logged.

## Baseline

Conformance goldens are recorded from the release named in `test/conformance/BASELINE`.
A change that lands during the freeze and alters behaviour must re-record the affected
goldens, and the PR must say so.
