# Evidence: contribution-input survives the 128 KiB argv limit

Change: `fm/fix-fleet-snapshot-argjson-overflow` (target 57bd5dc, base daaffdb).
Moves the `--contribution-input` mode of `bin/fm-fleet-snapshot.sh` off
`jq --argjson backlog "$BACKLOG_JSON"` (argv) onto a staged temp file read with
`--slurpfile`.

## Fixture
A large analytics-style backlog: 900 Queued task lines, `backlog.md` = 229,413 bytes,
which parses to a structured backlog JSON of ~1,005,853 bytes - far over Linux's
128 KiB (131,072) MAX_ARG_STRLEN single-argv limit.

## Base script (before fix) - reported failure reproduced
Run from `bin/` so sibling libs load, isolating the argv failure:

```
bin/fm-fleet-snapshot.basecheck.sh: line 1978: jq: Argument list too long
stdout bytes: 0
```

Line 1978 is the `jq -n --argjson backlog "$BACKLOG_JSON" ...` contribution site.
It dies, then the script hits `exit 0` - a silent break emitting no output.

Fed that empty output to the real consumer `fm-contributions.sh snapshot ... --all`:

```
{ "known": 0, "checked": 0, ... "unreadable_records": 1, "rows": [] }
```

All 900 contributions silently vanish - "the read fails at every analytics session start".

## Target script (with fix) - works
```
exit=0
stdout bytes: 1372211
.backlog.records | length  => 900
structured backlog JSON bytes: 1005853
```

Fed to the same consumer:

```
{ "known": 900, "checked": 0 }
```

Every record reaches the consumer intact.

## Durable regression test
Added `test_large_backlog_contribution_input_survives_argv_limit` to
`tests/fm-contributions.test.sh` (400-record backlog, asserts structured backlog
> 131072 bytes, 400 records read, consumer reports `known == 400` and
`unreadable_records == 0`).

- On the fixed tree: `ok - a backlog exceeding the argv limit is staged and read with every record intact`
- On the base script: `not ok - structured backlog only 0 bytes; too small to exercise the argv limit`
  (preceded by `jq: Argument list too long`) - fails before the fix, passes after.
