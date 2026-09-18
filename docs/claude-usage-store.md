---
summary: "Per-row Claude usage attribution and the SQLite store that is now the whole Claude scan state: schema, reconciliation, pricing, retention and the invariants each rests on."
read_when:
  - Working on Claude, Vertex or Bedrock local cost attribution
  - Changing the Claude transcript parser or its stored row shape
  - Touching the CostUsageStore schema, its migrations, or Claude reconciliation
  - Changing how local usage is priced, retained, or pruned
  - Querying Claude usage by project, session, branch, or backend
---

# Claude usage store

Claude usage is attributed **per transcript row** rather than per config directory, and those rows
live in SQLite. The store is not a cache beside a JSON artifact any more — it *is* the Claude scan
state, the only copy of the usage, and the source every ledger's report is read from. This is the
`#2760` migration for the Claude side of `CostUsageStore`.

One unfiltered scan per set of roots fills it; Claude, Vertex and Bedrock reports are `WHERE`
clauses over its `backend` column.

## Querying it

Full table-by-table reference, including the Codex half of the same database:
[`cost-usage-store-schema.md`](cost-usage-store-schema.md). The short version:

The database is `~/Library/Caches/CodexBar/cost-usage/cost-usage.sqlite`. Read it with `sqlite3`
directly; the app holds a WAL connection, so a reader sees a consistent snapshot without waiting.

Query `claude_reconciled_events` (cross-file winners) or `claude_event_costs` (the same rows with a
`cost_usd`), not `claude_usage_events` — that table keeps *every* parent/subagent candidate on
purpose, so summing it over-counts whenever a session has subagent copies of a request.

Subscription versus Bedrock over any period:

```sql
SELECT backend, SUM(input + cache_read + cache_create + output) AS tokens, SUM(cost_usd) AS usd
FROM claude_event_costs
WHERE day BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY backend;
```

`backend` is `firstParty` (Anthropic subscription or direct API), `bedrock` or `vertexAI` — the
`ClaudeLogBackend.rawValue`, not the `first-party` spelling reports use. The same rows answer by
project (`cwd`), session (`session_id`), branch (`git_branch`), model, or any combination:

```sql
SELECT cwd, model, SUM(cost_usd) AS usd
FROM claude_event_costs
WHERE backend = 'bedrock' AND day >= date('now', '-30 days', 'localtime')
GROUP BY cwd, model ORDER BY usd DESC;
```

`day` is a local-calendar day key (see the time-zone invariant), so compare it against local dates.
How far back this reaches is the ledger's retained window in `claude_ledger_state`, which widens to
the widest window anything has asked for and never narrows on its own.

Costs are list-price estimates for every backend; see
[the pricing policy](#every-backend-is-priced-at-official-list-rates-on-purpose) for why.

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

## Schema (v7)

Column-level reference for every table, Codex and Claude, is in
[`cost-usage-store-schema.md`](cost-usage-store-schema.md). This section covers why the Claude
tables have the shape they do.

### `claude_source_files`

Claude owns its own file namespace and does **not** reuse `files`. Every dependent of `files`
cascades on delete, and `retainDayWindow` prunes it using Codex coverage and fork rules — Claude
events hung off that table would be deleted by Codex retention.

Columns: `path`, `path_sort_key`, `file_identity`, `size`, `mtime_ms`, `parsed_offset`,
`coverage_since_day`, `coverage_until_day`, `parser_revision`, `tz_identity`, `complete`,
`source_present`.

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

See [Reconciliation](#reconciliation).

### `claude_ledger_state` (v7)

One row per ledger — `(roots_fingerprint, scan_since_day, scan_until_day, last_scan_ms,
generation)`. This is what the JSON artifact carried besides the rows: the window this ledger has
covered, when it last ran, and a counter that advances on every commit for report memos to key on,
in place of the artifact mtime they used to watch.

Keyed by roots, not by provider: what a scan covers is decided by the directories it walks, and
Claude, Vertex and Bedrock over the same roots are one scan. A profile-scoped `CLAUDE_CONFIG_DIR`
gets its own row because it walks its own roots.

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

#### Every backend is priced at official list rates, on purpose

The table is keyed by `(model, backend, …)` but seeded **identically for every backend**. That is a
decision, not an omission.

Bedrock and Vertex resell Claude under per-customer contracts CodexBar cannot see — committed-use
discounts, private offers, regional rates. A "Bedrock price" in this catalog would be some other
customer's price presented as yours, which is worse than an openly approximate number. So every row
is priced at Anthropic's published per-token rates, and reports say so: their `costProvenance` is
`listPriceEstimate`. The vendor's own invoice remains the authority for what was actually billed.

The `backend` column stays because the schema should be able to express a per-account rate if one is
ever supplied. Seeding it uniformly is the policy; the column is the mechanism.

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

## Migrations v3 → v7

Explicit and transactional, **not** via `adoptCompatiblePredecessor`. That hook proves same-base
parser compatibility only: `canAdoptPredecessor` recomputes the predecessor stamp from the *current*
`baseSchemaVersion`, so bumping the base makes every older database ineligible. `CREATE TABLE IF NOT
EXISTS` there could also bless a same-named wrong-shape table, since `validateDatabaseIntegrity`
checks only `quick_check` and `auto_vacuum`.

Order: validate v3 → `CREATE` the new objects (exact, not `IF NOT EXISTS`) → write `meta` and
`user_version` last → `foreign_key_check` → commit; roll back or rebuild on failure. This preserves
the live Codex ledger, whose discovery, accumulator, buffer and previous-report state a full rebuild
would discard.

Each step, and what it is for:

| step | change |
|---|---|
| v3 → v4 | the Claude tables, indexes and `claude_reconciled_events` |
| v4 → v5 | `claude_model_prices` in its corrected shape, plus the `claude_event_costs` view |
| v5 → v6 | `source_present` on `claude_source_files`, so a departure can be recorded |
| v6 → v7 | `claude_ledger_state`, which lets the store be the scan state |

v4's price table shipped with no writer and the wrong column types, so v5 drops and recreates it
rather than altering it; nothing can be carried across. Leaving it in place makes the migration's
exact `CREATE TABLE` collide, roll back and rebuild, which silently drops both ledgers — the same
trap as leaving a view behind on the v3 path. There is a regression test for exactly that.

**A fixture for an older version must undo every object that version did not have.** Today's code
creates them all, so a test that drops only some of them reproduces a shape no release ever shipped,
and the collide-rollback-rebuild above looks like a migration bug rather than a fixture bug. This bit
three times, once per added object, which is why `makeGenuinely(base:)` now expresses the whole
downgrade in one place.

Note that a clean `PRAGMA foreign_key_check` returns **no rows**, so it must be stepped directly —
`scalarText` treats `SQLITE_DONE` as a failure.

## The store is the scan state

There is no `claude-v6.json` any more. `claude_source_files` already carried every field the
artifact did — identity, size, mtime, parsed offset, coverage, parser revision, time zone — and
`claude_ledger_state` (v7) carries the rest: the window a ledger has covered, when it last ran, and
a `generation` that advances on every commit. Report memos key on that generation, replacing the
artifact mtime they used to watch. A ledger is one set of roots, not one provider: Claude, Vertex
and Bedrock over the same roots are one scan.

The artifacts were deleted once the store committed a complete replacement, which is the condition
their removal was always gated on. They had become three copies of the same data — two 85 MB JSON
files holding every backend's rows plus the 64 MB database — because making the scan unfiltered
meant each provider's artifact accumulated the whole vault.

### Append and replace

A file write is one of two modes, in one transaction with its file row.

- **Replace** — a first parse, a full reparse, or an identity change. Every event for that file is
  deleted before the new ones are inserted, so rows no longer in the transcript cannot survive.
- **Append** — the file grew and is being read from its recorded offset. Keyed rows upsert onto
  their new ordinal, which is the last-chunk-wins rule; unkeyed rows take fresh ordinals continuing
  from `MAX(row_index)`, rather than colliding with lines already stored.

Appending widens the file's recorded coverage instead of replacing it, because the earlier days are
still stored and narrowing coverage is what makes a wider window look falsely complete.

### One window per ledger, not per caller

A scan parses over the window the *ledger* retains, not the one its caller asked for, and prunes to
the same. Both follow from replacement being all-or-nothing for a file: re-parsing a transcript into
a narrower window and replacing its events would drop every day outside that window, and nothing
would restore them because the file itself never changed. A 30-minute refresh asking for 30 days and
a dashboard asking for 365 share one ledger, and the narrow one must not evict the wide one's
history. The retained window therefore only ever widens, through `MIN`/`MAX` on the ledger row.

## Only unfiltered scans may write

A scan persists **only when `claudeLogProviderFilter == .all`**.

A provider-scoped scan parses just the rows its filter admits. Because a file write replaces that
file's events, storing a filtered scan would persist a partial row set, and a later scan for a
different backend would swap those rows out entirely. The store holds every backend; the ledger
split is a `WHERE` clause over `backend`.

Such a scan therefore keeps nothing at all: it parses into memory and answers from that, with no
incremental offset to resume from and nothing left behind. Only tests and diagnostics take that
path; production always scans unfiltered.

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

**Retention and coverage.** Nothing else bounds these tables — a real vault is ~150k events across a
year, and a transcript never touched again keeps its rows forever. Every scan prunes its own roots to
the window its ledger retains, and `retainDayWindow` carries Claude across too. Pruning events while
keeping EOF offsets is what would make a later, wider window look falsely complete, so coverage is
clamped to what survived and `claudeSourceFilesNeedingReparse` names the files that can no longer
answer for an earlier day.

A source row is deleted only when it has **no events and is no longer on disk**. An archived
transcript with nothing left in the window describes nothing, and keeping its offsets *is* the
falsely-complete state. One still on disk keeps its row even with no events: a transcript that
reported no usage is still tracked, and dropping it would make every later scan reparse it in full.

**Archive, not mirror.** A transcript that leaves the disk is recorded as gone
(`source_present = 0`) and keeps the usage it already reported; the store is a usage record, and
once the JSON artifacts retire it is the only copy. Deleting a project therefore no longer reduces
reported usage, and a ledger whose root has vanished still reports its history until the day window
prunes it. A transcript restored at the same path cannot double-count: a changed identity replaces
that file's events, and a copy appearing at a new path is deduplicated by the reconciliation view.

**Time zone.** `day` is local-calendar derived and therefore not timeless. `tz_identity` records the
calendar each row was bucketed under, and because the sync compares the whole recorded file state,
a calendar change rewrites every file's events rather than leaving them bucketed under the old one.

**Re-stat at commit.** A transcript written to while it is being read is parsed only as far as it
went. The pre-parse stamp is what gets recorded — that is what makes the next scan notice — and the
file is stamped incomplete rather than complete. Its rows are still real; the file simply is not
fully covered yet. Reaching that window needs a seam, so `Options.claudeDidParseFileForTesting` runs
between the parse and the re-stat; a real race is not reproducible.

## Status

Complete. The store holds every Claude-family event, is the only Claude scan state, prices from its
own catalog, prunes itself, and answers each ledger's report. The `claude-v6.json` /
`bedrock-v6.json` artifacts are gone.

Deliberately not done: per-backend pricing. See
[Every backend is priced at official list rates](#every-backend-is-priced-at-official-list-rates-on-purpose).

### Verified against the real vault

A live v3 database (613 Codex files, 13,543 usage rows, no Claude tables) migrated straight through
to v7 and kept every Codex row. One unfiltered scan stores 1,997 transcripts and 149,100 events, and
every ledger is read back out of it.

Retiring the artifacts took the cache directory from 254 MB to 81 MB. A 30-day scan wrote a 30-day
ledger; asking for 365 days afterwards widened the window and reparsed the history back in, from
2026-08-19 to 2026-04-24, which is the widening path working on real data rather than in a fixture.

`Scripts/claude_usage_store_oracle.py` is the oracle: it re-reads the transcripts, redoes both
reconciliation stages and sums the tokens itself, touching no CodexBar code, because the app's own
numbers cannot be their own oracle. Run immediately after a refresh it agrees exactly — 1,997
transcripts and 149,100 events over 37 days, with only the current day drifting by the rows written
between the scan and the oracle. Its one deliberate simplification is that it does not reproduce the
recursive Vertex metadata walk, so the tokens the app attributes to Vertex land in its first-party
column and cancel exactly.

Pass it every root the ledger covers, which is what it now defaults to. Claude Desktop keeps
per-session transcripts under `Library/Application Support/Claude/local-agent-mode-sessions`, and
running the oracle against `~/.claude/projects` alone makes the store look like it invented rows.

The Bedrock ledger reported 12,055,913,128 tokens and $15,300.566024449987 — identical to what the
previous filtered-scan artifact held, so neither the read-path unification nor moving pricing into a
view changed a real number.

Not yet landed: backend-aware pricing — Bedrock rows still price against the first-party catalog
even though models.dev carries an `amazon-bedrock` provider, and Vertex rows likewise.

Design notes: `docs/superpowers/specs/2026-09-17-claude-usage-store-design.md`.
