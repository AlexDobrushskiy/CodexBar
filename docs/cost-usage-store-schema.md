---
summary: "Table-by-table reference for cost-usage.sqlite: what every Codex and Claude table stores, which are authoritative, and how to query them without double-counting."
read_when:
  - Querying local usage or cost directly with sqlite3
  - Adding, changing, or migrating a CostUsageStore table
  - Working out whether a table is authoritative or rebuildable
  - Debugging a scan that resumed, stalled, or reported the wrong total
---

# `cost-usage.sqlite` schema

One SQLite database holds all locally-derived usage for every provider that has local logs:

```
~/Library/Caches/CodexBar/cost-usage/cost-usage.sqlite
```

It is a cache in the sense that everything in it is re-derivable from the agents' own log files —
delete it and the next scan rebuilds it. It is *not* a cache in the sense of being disposable while
those logs still exist: Claude usage outlives its transcripts on purpose (see
[`claude-usage-store.md`](claude-usage-store.md)), so deleting the database loses history that the
transcripts no longer carry.

## Two halves, one file

The database has two independent namespaces that share nothing but the file:

| | Codex | Claude |
|---|---|---|
| tracked files | `files` | `claude_source_files` |
| per-request rows | `usage_rows` (JSON blobs) | `claude_usage_events` (columns) |
| totals | `day_aggregates`, `file_day_aggregates` | computed on read from the views |
| scan bookkeeping | `accumulators`, `discovery_state`, `lookback_state`, `buffered_lines`, `fork_lineage`, `token_snapshots` | `claude_ledger_state` |

They are deliberately separate. Every dependent of `files` is `REFERENCES files(id) ON DELETE
CASCADE` and Codex retention prunes `files` by its own coverage and fork rules — Claude events hung
off that table would be deleted by rules that know nothing about them.

Other providers (Cursor, Antigravity, pi sessions) do not use this database; pi keeps
`pi-sessions-v8.json` beside it, and the rest read their vendors' APIs.

## Opening it safely

```sh
sqlite3 ~/Library/Caches/CodexBar/cost-usage/cost-usage.sqlite
```

The app holds a WAL connection, so a reader gets a consistent snapshot without blocking it and
without waiting. Two things to know before writing anything:

- **The CLI has `foreign_keys` OFF by default.** The app sets `PRAGMA foreign_keys=ON`. A manual
  `DELETE FROM files` or `DELETE FROM claude_source_files` in `sqlite3` therefore orphans children
  instead of cascading. Turn it on, or delete through the app's own retention API.
- **Never order on `path`.** SQLite's `BINARY` collation compares UTF-8 bytes, Swift's `String <` is
  canonical-equivalence aware, and APFS stores filenames decomposed; they *invert* on non-ASCII
  paths. `claude_source_files.path_sort_key` exists for this — it is the path NFC-normalized and
  stored as bytes, and it is the one ordering authority the reconciliation view uses.

## Shared tables

### `meta`
`(key, value)`. One row: `parser_hash`, the fingerprint of the Codex parser the rows were written
by. Together with `PRAGMA user_version` it decides whether a database is current, migratable, or
must be rebuilt. See [migrations](claude-usage-store.md#migrations-v3--v7).

### `scan_metadata`
Singleton (`id = 1`) holding a JSON `CostUsageStoreMetadata` blob: last scan time, the scanned day
window, time zone, pricing key, catch-up progress counters, the previous published report, and
Codex priority-turn state. This is Codex's scan-level bookkeeping; Claude's equivalent is
`claude_ledger_state`.

## Codex tables

Codex's parse is stateful in a way Claude's is not — rollouts are large, resumable, and forkable —
so most of these tables exist to let a scan stop and continue rather than to hold usage.

### `files`
One row per tracked Codex rollout. Identity and progress: `path`, `inode`, `mtime_ms`, `size`,
`parsed_bytes`, the validation anchor (`anchor_indexed_bytes`, `anchor_window_start`,
`anchor_sha256`) that detects a rewritten prefix, a `scan_state` blob for resume, `session_id`, and
the day range this file's rows cover.

### `usage_rows`
**The Codex per-request fact.** `(file_id, row_index)` with a JSON `payload` per request:

```json
{"day":"2026-08-25","model":"gpt-5.6-sol","rawModel":"gpt-5.6-sol","turnID":"…",
 "eventIndex":0,"timestampUnixMs":1787686134573,"input":21120,"cached":0,"output":174,
 "reasoning":0,"pricingModel":"gpt-5.6-sol","pricingMode":"standard"}
```

The payload is JSON, so `json_extract` works on it — see the recipes below. `knownCostNanos` is
present only when the source gave an authoritative monetary cost; otherwise cost is resolved from
the pricing catalog when a report is read.

### `token_snapshots`
Cumulative token counters as seen at each event index, with the byte offset they were read at.
Codex rollouts report running totals rather than deltas, so these are what a resumed scan diffs
against to avoid double-counting. Not a usage table — do not sum it.

### `file_day_aggregates` / `day_aggregates`
Day × model totals, per file and rolled up. Both carry the token split (input, cached, output,
reasoning), `request_count`, `authoritative_cost_nanos` (vendor-supplied cost only, zero when cost
is estimated), and the standard/priority service-tier split. Derived — rebuildable from
`usage_rows` — and what reports read for speed.

### `accumulators`
Per file: the counted totals, the raw-totals baseline and watermark, and flags for divergent or
interleaved totals. This is the state that makes an incremental Codex parse arithmetically safe.

### `fork_lineage`
Per file: `session_id`, `forked_from_id`, fork timestamp, dependency key, and blobs of subagent and
accounting state. Codex sessions fork, and a fork shares a prefix with its parent; retention must
not delete a parent whose child still depends on it.

### `buffered_lines`
Lines parked mid-scan, keyed by `kind`: `pricingEvidence`, `subagent`, `unresolvedFork`,
`deferredReplay`. Each is a line that cannot be resolved until something else is parsed. Normally
empty.

### `discovery_state`, `lookback_state`
Singletons holding the resumable file-discovery walk and the historical back-fill cursor. Pure
bookkeeping; empty or stale rows here cost a rescan, not data.

## Claude tables

Rationale for the shape of these is in [`claude-usage-store.md`](claude-usage-store.md); this is the
column reference.

### `claude_source_files`
One row per tracked transcript. `path` + `path_sort_key` (see above), `file_identity` (`dev:inode`),
`size`, `mtime_ms`, `parsed_offset`, the covered day range, `parser_revision`, `tz_identity` (the
calendar `day` was bucketed under), `complete` (the file was fully read at commit), and
`source_present` (the transcript is still on disk — a departure is recorded, not erased).

The identity/size/mtime/offset quadruple is also the compare-and-set baseline a write is validated
against, which is what stops a stale writer overwriting a newer scan.

### `claude_usage_events`
**The Claude per-request fact**, one row per reconciled transcript line, as real columns:

| group | columns |
|---|---|
| identity | `file_id`, `row_index`, `message_id`, `request_id`, `session_id` |
| when | `ts_ms`, `day` (local-calendar key) |
| what | `backend`, `model` (normalized), `raw_model` (as written) |
| where | `cwd`, `git_branch`, `path_role` (`main`/`subagent`), `is_sidechain` |
| how | `effort`, `service_tier` |
| tokens | `input`, `cache_read`, `cache_create`, `cache_create_1h`, `output`, `thinking_tokens` |
| tools | `web_search_reqs`, `web_fetch_reqs` |
| cost at ingest | `ingest_cost_nanos`, `ingest_cost_priced` |

`backend` is `firstParty`, `vertexAI` or `bedrock` — `ClaudeLogBackend.rawValue`, not the
`first-party` spelling reports use.

This table keeps **every** candidate for a request, including the copies a subagent transcript makes
of its parent's rows. Summing it directly over-counts; query a view.

### `claude_reconciled_events` (view)
`claude_usage_events` plus `source_path`, with cross-file duplicates resolved to one winner per
`(backend, message_id, request_id)`: non-sidechain beats sidechain, `main` beats `subagent`, then
`path_sort_key`. Rows missing either id have no canonical identity and all survive. **This is the
table to sum.**

### `claude_model_prices`
`(model, backend, valid_from_ms)` with half-open validity windows and per-token rates, plus the
long-context tier. Seeded from the pricing catalog on every scan. Every backend is priced at
Anthropic list rates on purpose — see
[the pricing policy](claude-usage-store.md#every-backend-is-priced-at-official-list-rates-on-purpose).

### `claude_event_costs` (view)
`claude_reconciled_events` plus `cost_usd`, priced per event: long-context tier chosen from that
one request's tokens, 1h cache writes at twice the tier-selected input rate, falling back to the
ingest cost when the catalog cannot price the model. **This is the table to sum for money.**

### `claude_ledger_state`
One row per ledger — a ledger being one set of scanned roots, not one provider. `scan_since_day` /
`scan_until_day` is the window this ledger retains (it only ever widens), `last_scan_ms` drives the
refresh debounce, and `generation` advances on every commit for report memos to key on.

## What is authoritative

| | rebuildable from | lost if deleted |
|---|---|---|
| `usage_rows`, `token_snapshots`, `accumulators` | Codex rollouts | nothing, while the rollouts exist |
| `day_aggregates`, `file_day_aggregates` | `usage_rows` | nothing |
| `claude_usage_events` | Claude transcripts | **usage from transcripts since deleted or rotated** |
| `claude_model_prices` | the pricing catalog | nothing; reseeded next scan |
| discovery/lookback/buffered/ledger state | — | scan progress; costs a rescan |

## Query recipes

### Claude: subscription vs Bedrock, any period

```sql
SELECT backend,
       SUM(input + cache_read + cache_create + output) AS tokens,
       ROUND(SUM(cost_usd), 2) AS usd
FROM claude_event_costs
WHERE day BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY backend;
```

### Claude: spend by project and model

```sql
SELECT cwd, model, ROUND(SUM(cost_usd), 2) AS usd
FROM claude_event_costs
WHERE backend = 'bedrock' AND day >= date('now', '-30 days', 'localtime')
GROUP BY cwd, model
ORDER BY usd DESC;
```

### Claude: one session, or one branch

```sql
SELECT day, model, SUM(input + cache_read + cache_create + output) AS tokens
FROM claude_reconciled_events
WHERE session_id = '…'            -- or: git_branch = 'feature/x'
GROUP BY day, model ORDER BY day;
```

### Claude: where the tokens actually go

```sql
SELECT day,
       SUM(input) AS fresh,
       SUM(cache_create) AS writes,
       SUM(cache_read) AS reads,
       ROUND(1.0 * SUM(cache_read) / NULLIF(SUM(cache_create), 0), 1) AS reads_per_write
FROM claude_reconciled_events
WHERE day >= date('now', '-14 days', 'localtime')
GROUP BY day ORDER BY day DESC;
```

Expect `fresh` to be thousands against hundreds of millions of `reads` on an agentic workload —
almost every input token is a cache read. That is why a "percent served from cache" ratio is not
worth writing: it saturates at 100% and tells you nothing. `reads_per_write` does move, and is the
number that says whether a long session is paying for its cache.

### Codex: tokens by model, straight from the rows

```sql
SELECT json_extract(CAST(payload AS TEXT), '$.model') AS model,
       SUM(json_extract(CAST(payload AS TEXT), '$.input')
         + json_extract(CAST(payload AS TEXT), '$.output')) AS tokens
FROM usage_rows
GROUP BY model ORDER BY tokens DESC;
```

### Codex: the pre-aggregated view

```sql
SELECT day, model, input_tokens, cached_tokens, output_tokens, request_count
FROM day_aggregates
ORDER BY day DESC, model;
```

### Both halves on one day

```sql
SELECT 'claude' AS side, model, SUM(input + cache_read + cache_create + output) AS tokens
FROM claude_reconciled_events WHERE day = date('now', 'localtime') GROUP BY model
UNION ALL
SELECT 'codex', model, input_tokens + cached_tokens + output_tokens
FROM day_aggregates WHERE day = date('now', 'localtime');
```

## Pitfalls

- **Sum a view, not `claude_usage_events`.** The table keeps every parent/subagent candidate by
  design, so that deleting a winner reveals the loser rather than losing the usage.
- **`day` is a local-calendar key**, derived under the time zone in `tz_identity` — compare it
  against local dates (`date('now','localtime')`), not UTC.
- **Costs are list-price estimates** for every backend, and Codex costs are estimated at read time
  unless `authoritative_cost_nanos` is non-zero. The vendor's invoice is the authority.
- **How far back a query reaches** is the ledger's retained window, not the age of the logs. Widen
  it by asking the app for a longer history once; it never narrows on its own.
- **Codex bookkeeping tables are not usage.** `token_snapshots` holds cumulative counters, not
  per-request deltas; summing it produces a number with no meaning.

## Changing the schema

`baseSchemaVersion` in `CostUsageStore.swift`, packed with the parser hash into `user_version`.
Migrations are explicit and transactional, and adding an object means teaching the test fixture to
undo it — see [migrations](claude-usage-store.md#migrations-v3--v7) for the order and the trap that
has caught this three times.
