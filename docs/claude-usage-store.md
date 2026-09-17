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

See below.

### `claude_model_prices` and `claude_event_costs` (v5)

Tokens are the stored fact; cost is a view. `claude_model_prices` is versioned by
`(model, backend, valid_from_ms)` with half-open `[valid_from_ms, valid_to_ms)` windows, so exactly
one row can join an event — overlapping windows would multiply rows through the view.

Three deliberate departures from the first sketch of this table:

- **Rates are per token, not per Mtok.** The Swift formula multiplies per-token rates; dividing a
  per-million rate in SQL differs from it by an ulp on rates that are not exactly representable.
- **There is no stored 1h cache-write rate.** A one-hour cache write costs twice the *tier-selected*
  input rate, so a flat stored rate would contradict the formula on any long-context event.
- **Prices key on the normalized `model`, not `raw_model`.** Ingest prices each row by the id the
  transcript wrote, but a report has always repriced by the normalized identity its rows are
  bucketed under, so several dated spellings of one model report at one rate.

Model-id routing, aliases and catalog fallbacks stay in Swift — `CostUsagePricing.claudePricing`
resolves the rates and the scan seeds them for every model the store holds. Only the arithmetic is
in SQL. `claude_event_costs` selects the long-context tier **per event**, because thresholds are per
request and pre-aggregating tokens would price a busy day at the wrong tier. Its precedence matches
the report's: a row priced to exactly zero at ingest stays zero, then the current catalog, then the
ingest cost, then unpriced.

A row with no timestamp cannot be placed in a validity window, so it does not join and falls back to
its ingest cost. The parser requires a parseable timestamp, so that is a guard rather than a path.

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

## Migration v3 → v4 → v5

Explicit and transactional, **not** via `adoptCompatiblePredecessor`. That hook proves same-base
parser compatibility only: `canAdoptPredecessor` recomputes the predecessor stamp from the *current*
`baseSchemaVersion`, so bumping the base makes every older database ineligible. `CREATE TABLE IF NOT
EXISTS` there could also bless a same-named wrong-shape table, since `validateDatabaseIntegrity`
checks only `quick_check` and `auto_vacuum`.

Order: validate v3 → `CREATE` the new objects (exact, not `IF NOT EXISTS`) → write `meta` and
`user_version` last → `foreign_key_check` → commit; roll back or rebuild on failure. This preserves
the live Codex ledger, whose discovery, accumulator, buffer and previous-report state a full rebuild
would discard.

v4 → v5 adds `claude_model_prices` in its corrected shape and the `claude_event_costs` view. The v4
table shipped with no writer and the wrong column types, so it is dropped and recreated rather than
altered; nothing can be carried across. Leaving it in place makes the migration's exact `CREATE
TABLE` collide, roll back and rebuild, which silently drops both ledgers — the same trap as leaving a
view behind on the v3 path. There is a regression test for exactly that.

Note that a clean `PRAGMA foreign_key_check` returns **no rows**, so it must be stepped directly —
`scalarText` treats `SQLITE_DONE` as a failure.

## Only unfiltered scans may write

The mirror from a scan into the store runs **only when `claudeLogProviderFilter == .all`**.

A provider-scoped scan parses just the rows its filter admits. Because the mirror replaces a file's
events, storing a filtered scan would persist a partial row set, and a later scan for a different
backend would swap those rows out entirely. The store holds every backend; the ledger split is a
`WHERE` clause over `backend`.

## Scanning and reporting are separate scopes

`Options.claudeLogProviderFilter` is what the **scan** parses; `Options.claudeBackendScope` is what
the **report** covers. Production leaves the first at `.all` and sets the second per provider, so one
unfiltered pass over the transcripts fills the store and each ledger reads its own backends back out
of `claude_reconciled_events`. Filtering the scan instead is what kept the store empty: the gate
above refused every provider-scoped scan.

A ledger is also scoped to its own roots. The store is global, but a profile-scoped Claude scan
(`CLAUDE_CONFIG_DIR` per profile) walks only part of the vault, so both the report read and the
eviction sweep are bounded by that scan's configured roots. A root that has gone missing still
belongs to the ledger and its rows are swept; roots belonging to another profile are never touched.

## Invariants the store enforces

**Concurrency.** WAL serializes commits but does not stop a stale writer: A parses old file state,
B commits an append, then A acquires the lock and overwrites B. `writeClaudeFile` therefore carries
the baseline it parsed against — `(file_identity, size, mtime_ms, parsed_offset)` — and is rejected
when the recorded state has moved, handing back what is actually stored. `expecting: nil` asserts
the file is untracked, so two first writes cannot both win. The file row and its events move in one
transaction, which is what makes a replace atomic: a rejected write must not leave a file whose
events were already deleted.

**Retention and coverage.** Nothing else bounds these tables — a real vault is ~56k events per
30-day window, and a transcript never touched again keeps its rows forever. Every scan prunes its
own roots to its own scan window, and `retainDayWindow` carries Claude across too. Pruning events
while keeping EOF offsets is what would make a later, wider window look falsely complete, so
coverage is clamped to what survived and `claudeSourceFilesNeedingReparse` names the files that can
no longer answer for an earlier day. A file left with nothing in the window is dropped outright:
keeping its offsets *is* the falsely-complete state.

**Time zone.** `day` is local-calendar derived and therefore not timeless. `tz_identity` records the
calendar each row was bucketed under, and because the sync compares the whole recorded file state,
a calendar change rewrites every file's events rather than leaving them bucketed under the old one.

**Re-stat at commit.** A transcript written to while it is being read is parsed only as far as it
went. The pre-parse stamp is what gets recorded — that is what makes the next scan notice — and the
file is stamped incomplete rather than complete. Its rows are still real; the file simply is not
fully covered yet.

## Status

Landed: the schema and migrations, event storage, the reconciliation view, the parser detail fields,
the scan→store mirror, the unified read path — Claude, Vertex and Bedrock reports are now built from
the store — the price catalog with its cost view, which every report now reads its costs from, and
the concurrency, retention, coverage, time-zone and re-stat invariants above.

### Verified against the real vault

A live v3 database (613 Codex files, 13,543 usage rows, no Claude tables) migrated straight to v5
and kept every Codex row. One unfiltered scan then stored 1,941 transcripts and 146,101 events, and
both ledgers were read back out of it.

`Scripts/claude_usage_store_oracle.py` is the oracle: it re-reads the transcripts, redoes both
reconciliation stages and sums the tokens itself, touching no CodexBar code, because the app's own
numbers cannot be their own oracle. Run immediately after a refresh it agreed exactly — 146,101 rows
and 23,494,953,194 tokens on both sides, with all 29 days matching. Its one deliberate
simplification is that it does not reproduce the recursive Vertex metadata walk, so the 3,034,110
tokens the app attributes to Vertex land in its first-party column and cancel exactly.

The Bedrock ledger reported 12,055,913,128 tokens and $15,300.566024449987 — identical to what the
previous filtered-scan artifact held, so neither the read-path unification nor moving pricing into a
view changed a real number.

Not yet landed: backend-aware pricing (Bedrock rows still price against the first-party catalog
even though models.dev carries an `amazon-bedrock` provider) and retirement of the
`claude-v6.json` / `bedrock-v6.json` artifacts, which are still the incremental parse state. Each provider keeps its own artifact, so the first scan after this change
re-parses once per enabled Claude-family provider; the store write itself is skipped for files whose
recorded state has not moved.

Design notes: `docs/superpowers/specs/2026-09-17-claude-usage-store-design.md`.
