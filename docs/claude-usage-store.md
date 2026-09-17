---
summary: "Per-row Claude usage attribution: Bedrock/Vertex backend classification and the SQLite usage store that replaces the day×model JSON artifacts."
read_when:
  - Working on Claude or Bedrock local cost attribution
  - Changing the Claude transcript parser or its stored row shape
  - Touching the CostUsageStore schema, its migrations, or Claude reconciliation
  - Querying Claude usage by project, session, branch, or backend
---

# Claude usage store

Two related changes, both on this fork: Claude usage is attributed **per transcript row** rather than
per config directory, and those rows are persisted in SQLite instead of being collapsed into
day×model totals. This is the `#2760` migration for the Claude side of `CostUsageStore`.

## Why per-row attribution

Claude Code writes first-party, Vertex and Bedrock traffic into the *same* transcripts. Attributing
by `CLAUDE_CONFIG_DIR` — one config root per backend, each scanned as its own ledger — is therefore
only a proxy, and it drifts the moment a session is resumed under a different backend. Measured on a
real vault, a directory nominally holding only Bedrock traffic was **84% first-party** within two
days of being split.

The transcript itself is authoritative, so the backend is now read from the row.

## Backend classification

`CostUsageScanner.claudeLogBackend(obj:message:)` returns `firstParty`, `vertexAI` or `bedrock`.
Vertex is tested first so its long-standing (deliberately loose) metadata rules keep their exact
historical behaviour; Bedrock is only considered for rows Vertex did not claim.

Bedrock is recognised by two markers the API itself stamps:

- `_bdrk_` in `message.id` or `requestId` — e.g. `msg_bdrk_dmkwtqyoytda5f2q3lvl52jqh6ryynodcgeio`
- the `anthropic.claude-*` model namespace, optionally region- or ARN-qualified — e.g.
  `anthropic.claude-haiku-4-5-20251001-v1:0`, `us.anthropic.claude-opus-4-5-v1:0`

Unlike the Vertex classifier, Bedrock detection **never walks arbitrary metadata or message text**.
"bedrock" is an ordinary English word that appears in transcript prose, so a recursive match would
bill any conversation *about* Bedrock to the Bedrock ledger.

Note that Bedrock rows carry no `requestId` at all, which is why canonical identity has to tolerate
a missing id rather than assume one.

## Bedrock's ledger needs no AWS credentials

`BedrockLocalLedgerProbe` makes the Bedrock provider available when local transcripts contain
Bedrock-billed rows, independently of AWS credentials. Claude Code can authenticate to Bedrock with
`AWS_BEARER_TOKEN_BEDROCK`, which CodexBar never sees, and Cost Explorer reads are billed per
request — so CloudWatch/Cost Explorer stay an *optional vendor-metered overlay* over a ledger derived
entirely from local files. The probe is bounded (newest transcripts first, capped bytes per file,
first-hit exit) and runs behind the provider availability TTL cache.

## Schema (v4)

### `claude_source_files`

Claude owns its own file namespace and does **not** reuse `files`. Every dependent of `files`
cascades on delete, and `retainDayWindow` prunes it using Codex coverage and fork rules — Claude
events hung off that table would be deleted by Codex retention.

Columns: `path`, `path_sort_key`, `file_identity`, `size`, `mtime_ms`, `parsed_offset`,
`coverage_since_day`, `coverage_until_day`, `parser_revision`, `tz_identity`, `complete`.

### `claude_usage_events`

One row per reconciled transcript line, carrying what the JSON artifact discarded: `backend`,
`session_id`, `message_id`, `request_id`, `cwd`, `git_branch`, `path_role`, `is_sidechain`,
`effort`, `service_tier`, the full token split (`input`, `cache_read`, `cache_create`,
`cache_create_1h`, `output`), `thinking_tokens`, `web_search_reqs`, `web_fetch_reqs`, and
`ingest_cost_nanos` / `ingest_cost_priced`.

- `PRIMARY KEY (file_id, row_index)`
- `UNIQUE (file_id, backend, message_id, request_id) WHERE message_id IS NOT NULL AND request_id IS NOT NULL`
- index on `(backend, day, model)` — reports filter backend+day and group by model

`model` is normalized and `raw_model` is the model as written, so an alias or pricing change never
requires reparsing transcripts.

`cwd` is stored raw and the project is derived in a view. Baking a project name at ingest would be
unrecoverable; a view can be corrected without a rescan.

### `claude_reconciled_events`

See below. `claude_model_prices` is versioned by `(model, backend, valid_from)`; cost is a view over
events × prices, applied **per event** because long-context pricing tiers make pre-aggregation wrong.

## Reconciliation

Two ranking stages exist in the parser and both are preserved.

1. **Within a file** — streaming chunks sharing one `messageId:requestId` collapse, last cumulative
   chunk wins. Only that winner is persisted; an appended chunk upserts, updating `row_index` and
   every payload column.
2. **Across files** — a canonical identity can appear in a parent transcript and again in its
   subagent copies. *Every candidate is stored*, and the winner is chosen by the view, so deleting a
   winner reveals the loser rather than losing the usage.

Ranking mirrors `claudeRowWins` in `CostUsageScanner+Claude.swift`: non-sidechain beats sidechain →
`main` beats `subagent` → path sort key. Canonical identity is partitioned by backend.

The view is `unkeyed UNION ALL keyed_rank_1`. Rows without both ids have no canonical identity and
take a synthetic one from `(file_id, row_index)`; sharing a window partition over NULL ids would
collapse them into a single row.

### One ordering authority for the path tie-break

The tie-break orders on `path_sort_key`, **never on `path`**. The key is the path NFC-normalized
(`precomposedStringWithCanonicalMapping`) stored as UTF-8, which the view byte-compares.

SQLite's `BINARY` collation compares UTF-8 bytes; Swift's `String <` is canonical-equivalence aware;
APFS stores filenames decomposed. Measured on `/p/cafe<U+0301>/` versus `/p/cafz/`:

| | `nfd < z` | `nfc == nfd` |
|---|---|---|
| Swift | `false` | `true` |
| SQLite `BINARY` | `true` | `false` |

They invert. Ordering on the raw path would make the view and the scanner disagree about which
equal-rank sidechain wins for any non-ASCII project path.

## Migration v3 → v4

Explicit and transactional, **not** via `adoptCompatiblePredecessor`. That hook proves same-base
parser compatibility only: `canAdoptPredecessor` recomputes the predecessor stamp from the *current*
`baseSchemaVersion`, so bumping the base makes every older database ineligible. `CREATE TABLE IF NOT
EXISTS` there could also bless a same-named wrong-shape table, since `validateDatabaseIntegrity`
checks only `quick_check` and `auto_vacuum`.

Order: validate v3 → `CREATE` the new objects (exact, not `IF NOT EXISTS`) → write `meta` and
`user_version` last → `foreign_key_check` → commit; roll back or rebuild on failure. This preserves
the live Codex ledger, whose discovery, accumulator, buffer and previous-report state a full rebuild
would discard.

Note that a clean `PRAGMA foreign_key_check` returns **no rows**, so it must be stepped directly —
`scalarText` treats `SQLITE_DONE` as a failure.

## Only unfiltered scans may write

The mirror from a scan into the store runs **only when `claudeLogProviderFilter == .all`**.

A provider-scoped scan parses just the rows its filter admits. Because the mirror replaces a file's
events, storing a filtered scan would persist a partial row set, and a later scan for a different
backend would swap those rows out entirely. The store holds every backend; the ledger split is a
`WHERE` clause over `backend`.

## Status

Landed: the schema and migration, event storage, the reconciliation view, the parser detail fields,
and the scan→store mirror. Verified against a real vault — 1,921 transcripts and 55,921 events, with
the Codex ledger preserved across the migration.

Not yet landed: the Claude and Bedrock **read paths** still build reports from the filtered
`claude-v6.json` / `bedrock-v6.json` artifacts rather than from the store, so in normal operation
those provider-scoped scans are filtered and the mirror correctly declines to write. Until the read
paths are unified onto one unfiltered scan plus a backend `WHERE` clause, the store stays empty
outside tests. Pricing views and retirement of the JSON artifacts follow that.

Design notes: `docs/superpowers/specs/2026-09-17-claude-usage-store-design.md`.
