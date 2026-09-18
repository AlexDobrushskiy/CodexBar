---
summary: "Design for the Claude usage store: v4 schema, v3 to v4 migration, reconciliation, and pricing contracts."
read_when:
  - Implementing or reviewing the Claude usage store
  - Questioning a schema, reconciliation, or migration decision and its rationale
---

# Claude usage store (#2760 migration) — design

Branch `claude-usage-store` off `claude-bedrock-ledger`, Alex's fork only, not upstreamed.

Reference, not a recap: only decisions, interfaces and invariants that are not obvious from the code.

## Goal

Move Claude/Bedrock usage off the `claude-v6.json` / `bedrock-v6.json` whole-file artifacts onto
`CostUsageStore` sqlite, retaining per-event detail so usage is queryable by project, session,
branch and backend — by Alex, by an agent, or by a future frontend.

**Non-goal:** fixing a scan-instability bug. No such bug exists; the earlier report was an artifact
of a verification script reading JSON by recursive key search. Under 8 controlled runs every reading
is identical. This migration is justified by queryability alone.

## Schema (v4)

### `claude_source_files`

Claude gets its **own** file namespace. It must not reuse `files`: `token_snapshots`, `usage_rows`
and `file_day_aggregates` are all `REFERENCES files(id) ON DELETE CASCADE`, and `retainDayWindow`
prunes `files` by Codex coverage/fork rules — Claude events hung off it would be silently deleted.

```
id, path, file_identity, size, mtime_ms, parsed_offset,
coverage_since_day, coverage_until_day, parser_revision,
tz_identity, path_sort_key, complete
```

### `claude_usage_events`

```
file_id -> claude_source_files(id) ON DELETE CASCADE
row_index            physical ordinal; for keyed rows, the winning line's ordinal
ts_ms, day           day is local-calendar derived -- see tz invariant
backend              firstParty | vertexAI | bedrock
model, raw_model     normalized + as-written, so alias/pricing changes need no reparse
session_id, message_id, request_id
cwd, git_branch      stored raw; project is derived in a view, never baked at ingest
path_role            main | subagent
is_sidechain
effort, service_tier
input, cache_read, cache_create, cache_create_1h, output
thinking_tokens, web_search_reqs, web_fetch_reqs
ingest_cost_nanos, ingest_cost_priced
PRIMARY KEY (file_id, row_index)
UNIQUE (file_id, backend, message_id, request_id)
  WHERE message_id IS NOT NULL AND request_id IS NOT NULL
```

Indexes: the partial unique above, plus `(backend, day, model)`. Reports filter backend+day and
group by model; `(day, backend)` alone is the wrong shape.

### `model_prices`

`(model, backend, valid_from, valid_to, input_per_mtok, cache_read_per_mtok, cache_write_per_mtok,
cache_write_1h_per_mtok, output_per_mtok, long_context_threshold, long_context_*_per_mtok)`,
seeded from `ModelsDevPricing` plus manual Bedrock rows. Exactly one active pricing version, or a
parameterless view multiplies rows.

## Reconciliation

Two ranking stages already exist in the parser and both must be preserved.

1. **Within file** — streaming chunks sharing `messageId:requestId` collapse, last cumulative chunk
   wins. Persist only that winner; an appended chunk **upserts**, updating `row_index` and every
   payload column. Storing every physical line instead would require reimplementing this stage in SQL
   for no analytic gain.
2. **Across files** — parent vs subagent copies of one canonical key. All candidates stay in the
   table; the winner is chosen in a **view**, so deleting a winner reveals the loser.

Canonical identity is `(backend, message_id, request_id)`. Ranking, matching
`CostUsageScanner+Claude.swift:293` (`claudeRowWins`): non-sidechain beats sidechain → `main` beats
`subagent` → path tie-break.

View shape: `unkeyed UNION ALL keyed_rank_1`. Unkeyed rows take a synthetic identity from
`(file_id, row_index)` — sharing a window partition over NULL IDs would collapse them into one.

### Path tie-break: one ordering authority

The tie-break orders on a persisted `path_sort_key`, **never on `path`**. The key is the path
NFC-normalized (`precomposedStringWithCanonicalMapping`) and stored as UTF-8; the view byte-compares
it. A comparator is not a key, so "use Swift's comparison" is not implementable directly — NFC + byte
order is the concrete form, verified to reproduce Swift `String <` on precomposed/decomposed pairs,
Cyrillic vs ASCII, and plain ASCII.

Swift `String <` is canonical-equivalence aware; SQLite `BINARY` is byte-wise; APFS stores filenames
decomposed. Measured on `/p/cafe<U+0301>/` vs `/p/cafz/`:

| | `nfd < z` | `nfc == nfd` |
|---|---|---|
| Swift | `false` | `true` |
| SQLite BINARY | `true` (1) | `false` (0) |

They invert. Relying on the collations coinciding would make the scanner and the view disagree about
equal-rank sidechain winners for any non-ASCII path.

## Migration v3 → v4

Explicit and transactional. **Not** via `adoptCompatiblePredecessor`: that hook proves same-base
parser compatibility only — `canAdoptPredecessor` recomputes the predecessor from the *current*
`baseSchemaVersion`, so bumping base 3→4 makes every v3 DB ineligible, and `CREATE TABLE IF NOT
EXISTS` there could bless a same-named wrong-shape table, since `validateDatabaseIntegrity` checks
only `quick_check` and `auto_vacuum`.

Order: validate v3 → `CREATE` the new tables/indexes (exact, not `IF NOT EXISTS`) → write
`meta`/`user_version` last → validate v4 + `foreign_key_check` → commit; rollback or rebuild on
failure. `CREATE TABLE` does not disturb `auto_vacuum=2`. Preserves the live Codex rows, whose
discovery/accumulator/buffer/previous-report state a full rebuild would discard.

Legacy JSON artifacts are deleted **only after** the SQL scan transaction commits a complete
replacement. `removeLegacyCodexArtifactIfPresent` is Codex-specific and itself rebuilds — do not
reuse it.

## Invariants

- **Concurrency.** WAL serializes commits but does not stop a stale writer: A parses old state, B
  commits an append, A then overwrites B. Write transactions do optimistic CAS against the prior
  `(file_identity, size, mtime, parsed_offset)` baseline and reject/reload when it moved. Full
  reparse or identity replacement atomically deletes all of that file's events before inserting.
  Re-stat the source at commit before stamping `complete`.
- **Coverage.** Deleting old events while keeping EOF offsets makes a later wider window look
  falsely complete. `claude_source_files` records coverage and forces full reparse on window
  expansion.
- **Time zone.** `day` is local-calendar derived and therefore not timeless. Store `tz_identity`;
  invalidate and rebucket when it changes.
- **Pricing.** Tokens are the immutable fact. Cost is a view applying per-event long-context
  threshold selection, effective-date cutoffs and 1h cache-write pricing, falling back to
  `ingest_cost_*` when the current catalog misses. Aggregating tokens before pricing is wrong.

## Verification

Reuse the existing fixtures in `Tests/CodexBarTests/CostUsageScannerClaudeRegressionTests.swift`
rather than writing new ranking tests — assert the **view** reproduces their totals:

| fixture | line | asserts |
|---|---|---|
| cross-file parent/subagent dedup | 305 (expects 255 at 416) | parent wins, unique sidechain kept |
| copied history across forked parents | 419-513 | fork lineage |
| equal-rank sidechains | 516-586 | path tie-break |
| later parent displaces cached sidechain | 660-760 | winner displacement |

New store-level assertions:

1. Streaming append leaves exactly one keyed candidate, with the newest `row_index`.
2. Two unkeyed rows both survive.
3. Full reparse removes keyed rows no longer present.
4. Deleting the parent source reveals the retained sidechain loser.
5. Two stale-baseline writers cannot regress file state.
6. NFD non-ASCII path: view and scanner pick the same equal-rank winner.

Plus an oracle check — `SUM()` over `claude_usage_events` equals an independent count over the same
transcripts — and the full supported suite via
`/opt/homebrew/bin/python3.14 Scripts/run_swift_test.py` (pyenv shadows `python3`, which lacks
`waitid`, and `xattr`, which breaks `make release`).

**Test guard:** fixtures must run against a private `cacheRoot`. Setting `CLAUDE_CONFIG_DIR` without
`HOME` writes through to the ambient `~/Library/Caches/CodexBar` artifacts — this already happened
once and truncated the real `bedrock-v6.json`.

## What implementation changed

This spec is the design as approved. Where the built thing differs, the living doc
(`docs/claude-usage-store.md`) is authoritative; the deltas worth knowing:

| spec said | built instead | why |
|---|---|---|
| `model_prices` with `*_per_mtok` columns | per-token columns, no stored 1h rate, keyed on normalized `model` | per-Mtok division and a flat 1h rate each disagree with the Swift formula by an ulp; reports have always repriced on the normalized identity |
| seed "manual Bedrock rows" | every backend seeded at Anthropic list rates | Bedrock and Vertex resell under per-customer contracts CodexBar cannot see, so a stored "Bedrock price" would be someone else's |
| the JSON artifacts retire after the SQL path lands | they are gone, and the store is the scan state | `claude_ledger_state` (v7) carries the window and generation the artifact held; keeping it meant three copies of the same rows |
| the sweep deletes rows for vanished transcripts | a departure is recorded (`source_present`), rows stay | the store is the only copy now, so a rotated transcript must not take its usage with it |
| a scan covers the window its caller asked for | a scan covers the window its *ledger* retains | replacement is all-or-nothing per file, so a narrow reparse would drop a wide reader's history and nothing would restore it |
| base v4 | base v7 | one bump per added object: prices (v5), `source_present` (v6), ledger state (v7) |

Two invariants the spec named turned out to have teeth in ways the text did not anticipate, both
caught by tests rather than by review: the retention/coverage pair, which a 30-day refresh used to
violate against a 365-day dashboard, and the "genuine older version" fixture rule, which bit once
per added schema object.

## Risk

Vendored-file churn against upstream, accepted: `#2760` states this direction and it is Alex's fork.
