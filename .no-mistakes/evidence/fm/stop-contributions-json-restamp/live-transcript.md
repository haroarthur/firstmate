# Live drive: fm-contributions.sh poll must not restamp backups

Drove the real `bin/fm-contributions.sh` poll/snapshot CLI in isolated homes
with a local `gh` fixture (no network). Clock: `FM_CONTRIBUTIONS_NOW`.

## 1. Stable re-poll does not churn data/<task>/contributions.json

After an initial poll, `records[0].checked_at` was aged to `2026-09-15T08:00:00Z`
(well past MAX_AGE=900s) while observation stayed identical. Re-poll at
`2026-09-16T09:00:00Z`:

- contributions.json SHA-256 unchanged: `8ea51da1c5f733fba279ff84ba526722266f81ece4c7919e4f5c8728756c2ee4`
- durable `checked_at` still `2026-09-15T08:00:00Z` (not rewritten)
- `state/contributions-checked.json` stamped `2026-09-16T09:00:00Z`
- snapshot: `checked=1`, `complete=true`, actor maintainer (not fleet "not recently checked")

## 2. A real forge change still rewrites the backup

Same home, maintainer OWNER comment added, poll at `2026-09-16T09:01:00Z`:

- contributions.json changed; `checked_at=2026-09-16T09:01:00Z`; pending length 1
- stdout: `contribution-wake: check: contributions delivery 54ab06b3...`

## 3. Pending wake still publishes when the data write is skipped

Cleared `notified` and the wake queue after a captured comment, re-polled:

- observation and pending unchanged
- stdout: `contribution-wake: check: contributions delivery ee89cced...`
- one durable check wake; `notified` length 1

## 4. Oldest-first follows the state clock

Issue/9 clock set earlier than pull/8. Forge call log:

```
api repos/o/r/issues/9
...
api repos/o/r/pulls/8
```

Issue observed before the pull.

## 5. Budget exhaustion leaves record and clock untouched

`FM_CONTRIBUTIONS_BUDGET=1` with a 4s hang on `api repos/o/r/pulls/8`:

- prior contributions.json kept
- `state/contributions-checked.json` absent

## 6. Merged PR restamp skip stays nobody, not fleet refresh

Forge reported `state=closed` + `merged_at`. After merge observation, durable
`checked_at` aged to `2026-09-15T08:00:00Z`, stable re-poll at `09:00:00Z`:

- contributions.json bytes identical
- snapshot row: `actor=nobody`, `reason=forge reports merged`, `checked=true`
- counts: nobody 1, fleet 0 (not "terminal observation needs refresh")

## 7. Persist abort does not stamp a newer clock

New maintainer comment, then `chmod 555` on `data/delivery` so `write_record`'s
mktemp fails. Poll at `2026-09-16T09:00:00Z` exited 1:

- stderr: `mktemp: ... Permission denied`
- contributions.json unchanged (comment not persisted)
- state clock still `2026-09-16T08:00:00Z` (URL stays oldest)

## Colocated tests

`tests/fm-contributions.test.sh` exited 0, including:

- poll skips a checked_at-only restamp and still writes real observation changes
- poll retries pending wake publication when skipping a restamp
- poll observes the oldest local clock entry first
- budget exhausted mid-observation keeps the prior record and stays silent
