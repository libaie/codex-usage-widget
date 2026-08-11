# Normalized local observation contract v1

The Windows and macOS implementations consume Codex session JSONL independently and must produce the same normalized values for every case in this directory.

## Fixed rules

- `schemaVersion` is the integer `1`; an unknown major version is unsupported.
- `sourceKind` is `local-session-observation`.
- Token counts are non-negative signed 64-bit integers and serialize as decimal strings. Invalid or overflowing values become `null`; arithmetic never wraps.
- Timestamps normalize to signed 64-bit Unix epoch milliseconds in UTC.
- Percentages use decimal arithmetic and midpoint-to-even rounding to one decimal place, then serialize as strings.
- `resetAt <= now` is expired.
- Missing scalar values are `null`; collections are present and use `[]` when empty.
- Limit windows sort by remaining percentage, primary before secondary on a tie, then reset time and stable identifier.
- Well-formed records without a rate-limit payload are ignored. Unknown usage schema versions remain unsupported.
- An explicit `limit_id` of `codex` takes precedence; legacy records without `limit_id` are used only when no explicit `codex` record exists. Other model-specific pools never replace the main Codex limit.
- Tasks sort by observation time descending, then identifier using ordinal comparison.
- `complete`, `partial`, `unsupported`, `error`, and `empty` are distinct outcomes. Partial, stale, unsupported, and error data never trigger reminders.

`expected-state.json` is reviewed input. Platform implementations may not regenerate it from their own output.
