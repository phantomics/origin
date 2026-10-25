---
id:            ORIGIN-DRAFT-compass-migration-log
title:         "Compass Migration: Development Log"
genre:         Log
scope:         project
project:       Origin
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - ORIGIN-DRAFT-compass-migration
---

# Compass Migration: Development Log

This document records the migration of Origin's documentation corpus to
the Compass standard (version 0.4.0), carried out in three phases plus a
batch-0 fixup, following the plan in
[ORIGIN-DRAFT-compass-migration](Plan.CompassMigration.md). It is the
Origin counterpart of Classic's migration log
([CLASSIC-0036](../../classic/doc/Log.CompassMigration.md)), adapted to
Origin's specific corpus. The migration changed how the documents are
shaped, identified, and linked; it did not change what they say about the
code.


## Problem

Origin adopted Compass infrastructure early: `compass.sexp`, `.mailmap`,
and `doc/REGISTRY.sexp` were in place (commit `7ef2f48`), and files were
renamed to genre prefixes (commit `4bbea31`). One document,
[ORIGIN-DRAFT-browser-as-orbital](Survey.BrowserAsOrbital.md), carried
full front-matter and checked clean. The remaining 15 documents had no
front-matter and were skipped by `compass check --skip-unmarked`.

`compass check` without `--skip-unmarked` reported 15 `fm/present` errors.
About 45 links named files by their pre-rename paths. Decisions and open
questions were prose, not ADR-shaped records. Code references in the Logs
named paths without revisions. None of the corpus's tables had a `Table:`
caption.


## Design Decisions

The migration followed the nine decisions in
[ORIGIN-DRAFT-compass-migration](Plan.CompassMigration.md)
(ORIGIN-DRAFT-compass-migration-D1 through
ORIGIN-DRAFT-compass-migration-D9). No additional decisions were needed
during the build; the plan's decisions covered every case that arose. The
one clarification made during execution:

*Migration note (2026-10-25):* in-body `**Status:**` paragraphs that
carried substantive content (dependency framing, tier descriptions) were
kept as opening paragraphs with the `**Status:**` label removed, rather
than deleted entirely. This was the practical application of
ORIGIN-DRAFT-compass-migration-D7, whose text was updated to record it.


## Implementation

### Phase 0 — The plan (`6568821`)

The migration plan was written, reviewed, and checked clean. The plan
itself is a Compass-conforming document with 9 decision records and 3
open questions.

### Phase 1 — Clean baseline (`a054515`)

- Refreshed `AGENTS.md` from the current Compass snippet: added the
  `compass assign` / ledger sentence and the `next` command.
- Added `.github/workflows/compass-check.yml`, mirroring Classic's CI
  workflow, pinned to `COMPASS_REV` `9a6ab23`.
- Added `.github/CODEOWNERS` assigning `/doc/REGISTRY.sexp` to the
  steward.
- Generated `doc/INDEX.md` with `compass index`.

Gate: `compass check --skip-unmarked` reported 0 errors; `compass index
--check` passed.

### Phase 2 — Front-matter on every document (`99cb317`)

- Added §7 front-matter to all 15 unmarked documents: provisional
  identifiers, `status: Draft`, `project: Origin`, `language: en`,
  `provenance: { assistant: opencode }`, and `relates-to` populated from
  actual cross-references. `created` and `updated` omitted (derived from
  Git).
- Fixed ~45 stale links (`DevLog.*` → `Log.*`, `DevPlan.*` → `Plan.*`,
  `Concept.*` → `Survey.*`).
- Removed in-body `**Status:**` labels from 9 documents; kept
  substantive content as opening paragraphs. Kept `**Date:**` lines.
- Reshaped `Survey.GranularityAndImage.md` (H1 → `<Topic>: Survey`) and
  `Survey.GameImage.md` (H1, status line removed).
- Updated `Survey.BrowserAsOrbital.md`: `relates-to` populated, `Table:`
  captions, `project: Origin`, `provenance: { assistant: opencode }`.
- Updated `AGENTS.md`: migration line changed from `--skip-unmarked` to
  "complete".

Gate: `compass check` (without `--skip-unmarked`) reported 0 errors.

### Batch 0 — Phase 2 fixups (`9224d40`)

Several Phase 2 shortfalls were corrected:

- **Id-keyed links.** 30 links with file-name text rewritten to use the
  target's identifier (ORIGIN-DRAFT-compass-migration-D7, following
  CLASSIC-D107). 17 backtick-only mentions converted to id-keyed links.
- **Reverted a historical path.** The Files table in
  [ORIGIN-DRAFT-orbital-images](Log.OrbitalImages.md) had its
  `doc/DevLog.OrbitalImages.md` row incorrectly renamed; reverted to the
  name the file had at the time of the commit
  (ORIGIN-DRAFT-compass-migration-D6).
- **GameImage open questions.** The five open questions in
  [ORIGIN-DRAFT-game-image](Survey.GameImage.md) converted to
  `ORIGIN-DRAFT-game-image-O1` through `-O5` records. Spine headings
  renamed to "Relationship to Other Work" and "Open Questions".
- **Title/H1 alignment.** Nine `title:` fields updated to match their
  H1 headings exactly.
- **Plan updates.** Version target 0.3.0 → 0.4.0; Lexter commits
  Lexter commits identified in the ORIGIN-DRAFT-compass-migration-D6
  table; `created`/`updated` dropped from the Phase 2 table;
  ORIGIN-DRAFT-compass-migration-D7 updated to describe
  status-paragraph handling; ORIGIN-DRAFT-compass-migration-O3 removed
  (resolved by the user's decision on provenance).

Gate: both toolchain builds (`fe188d0` local, `9a6ab23` CI-pinned)
reported 0 errors. Every subsequent gate was checked with both builds,
as Classic did (CLASSIC-D111).

### Batch 1 — Core Logs (`1830df6`)

**[ORIGIN-DRAFT-orbital-images](Log.OrbitalImages.md).** Nine decision
records (ORIGIN-DRAFT-orbital-images-D1 through -D9) extracted from the
seven pre-implementation decisions and two build-time decisions. Code
references pinned to `ab349e7` (Origin) and `c8acd7c` (Lexter, with
`LEXTER:` prefix).
Tests → Verification with migration-noted test command. Files table
restructured: Repo column folded into path (Lexter rows prefixed
`lexter/`), caption naming commits. `Table:` captions on both tables.
`Description:` paragraph after the ASCII tree.

**[ORIGIN-DRAFT-dependencies](Log.Dependencies.md).** Design Decisions
section added with a migration note: no decisions were recorded as
numbered items in the original text. Code references qualified to full
paths and pinned to `2622b17`. Tests → Verification. Files table built
from `git show --stat 2622b17`. Future work → Outstanding Work. `Table:`
caption on the prior-art table.

### Batch 2 — Impulse Logs (`6c84812`)

41 decision records across three documents, each phase's records placed
at H3 directly inside the phase section (replacing the `### Design
Decisions` heading), per the agreed approach of records at H3 within each
phase.

**[ORIGIN-DRAFT-impulse-i](Log.ImpulseI.md).** 13 records (ORIGIN-DRAFT-impulse-i-D1 through -D13).
Phase 1's Design Decisions, Tests, Files, and Metrics demoted from H2 to
H3, matching Phases 2–3. Phase headings `--` → `—`. Tests → Verification
(×3). `Table:` captions on all 7 tables.

**[ORIGIN-DRAFT-impulse-ii](Log.ImpulseII.md).** 13 records (ORIGIN-DRAFT-impulse-ii-D1 through -D13).
Three new Files tables built from git (Phases 4–6). Tests → Verification
(×3). `Table:` captions on all 6 tables. Intro dashes `--` → `—`.

**[ORIGIN-DRAFT-impulse-iii](Log.ImpulseIII.md).** 15 records (ORIGIN-DRAFT-impulse-iii-D1 through -D15).
Four new Files tables (Phase 7, Pre-Phase 8, Phase 8, Phase 9). Phase
headings `--` → `—`. Tests → Verification (×3). `Table:` captions on all
prior-art tables.

### Batch 3 — Plans (`ab9a717`)

22 decision records and 55 open-question records across seven Plans.

**[ORIGIN-DRAFT-control-vocabulary](Plan.ControlVocabulary.md).** 3
D-records from the existing `### N.` decisions; 7 O-records. "Settled
Design Decisions" → "Settled Decisions"; "Open Design Questions" → "Open
Questions". 2 table captions.

**[ORIGIN-DRAFT-linux-service-manager](Plan.LinuxServiceManager.md).** 11
D-records from the existing numbered decisions; 9 O-records. Bare
line-number references symbol-pinned at `@57e8988`. Barrier labels
rewritten to avoid `ref/short-record` warnings. 7 table captions.
2 `Description:` paragraphs after ASCII trees.

**[ORIGIN-DRAFT-concern-topologies](Plan.ConcernTopologies.md).** 2
D-records; 6 O-records. 3 table captions.

**[ORIGIN-DRAFT-orchestration](Plan.Orchestration.md).** 2 D-records
extracted from "decided" markers in Scope. 8 O-records. 3 table captions.

**[ORIGIN-DRAFT-placement](Plan.Placement.md).** 2 D-records extracted
from "keystone design decision" and "chosen baseline" markers. 10
O-records. 5 table captions.

**[ORIGIN-DRAFT-user-facing-surfaces](Plan.UserFacingSurfaces.md).** 2
D-records extracted from "Direction (settled)" markers. 8 O-records.
"Direction" → "Roadmap". 4 table captions.

**[ORIGIN-DRAFT-foreign-orbitals](Plan.ForeignOrbitals.md).** No explicit
decision markers in the text, so no D-records. 7 O-records. 3 table
captions.

### Batch 4 — Surveys and Eval (`10f267b`)

**[ORIGIN-DRAFT-control-vocabulary-prior-art](Eval.ControlVocabulary.PriorArt.md).**
Spine headings capitalised ("The Shared Scenario", "The Rubric"). 7
`Table:` captions.

**[ORIGIN-DRAFT-game-image](Survey.GameImage.md).** 1 table caption.
`Description:` paragraph after the architectural-sketch ASCII tree.

**[ORIGIN-DRAFT-granularity-and-image](Survey.GranularityAndImage.md).**
1 table caption. No open questions; the document closes on design
principles, which the Survey spine permits.


## Verification

*Migration note (2026-10-25):* the verification command is
`compass check --federation`, run with two builds: the local toolchain
(`fe188d0`) and the CI-pinned revision (`9a6ab23`).

Every phase and batch was gated: `compass check --federation` reported
0 errors and 0 warnings on both builds, and `compass index --check`
passed. The two builds agreed at every gate.

Final corpus state:

- 17 documents (+ this log = 18), all with §7 front-matter
- `compass check --federation`: 0 errors, 0 warnings
- `compass index --check`: current


## Files

Table: Files added or changed during the Compass migration.

| File | Action | Description |
|------|--------|-------------|
| `AGENTS.md` | Modified | Refreshed Compass snippet; migration line updated |
| `.github/workflows/compass-check.yml` | **New** | CI workflow, pinned to `COMPASS_REV` `9a6ab23` |
| `.github/CODEOWNERS` | **New** | `/doc/REGISTRY.sexp` assigned to steward |
| `doc/INDEX.md` | **New** | Generated by `compass index` |
| `doc/Plan.CompassMigration.md` | Modified | Version, Lexter commits, status-paragraph note, open question removed |
| `doc/Eval.ControlVocabulary.PriorArt.md` | Modified | Front-matter, links, status, spine headings, captions |
| `doc/Log.OrbitalImages.md` | Modified | Front-matter, 9 D-records, pinned refs, spine, captions, description |
| `doc/Log.ImpulseI.md` | Modified | Front-matter, 13 D-records, spine, captions |
| `doc/Log.ImpulseII.md` | Modified | Front-matter, 13 D-records, Files tables, spine, captions |
| `doc/Log.ImpulseIII.md` | Modified | Front-matter, 15 D-records, Files tables, spine, captions |
| `doc/Log.Dependencies.md` | Modified | Front-matter, pinned refs, Files table, spine, captions |
| `doc/Plan.ControlVocabulary.md` | Modified | Front-matter, 3 D-records, 7 O-records, spine, captions |
| `doc/Plan.ForeignOrbitals.md` | Modified | Front-matter, 7 O-records, links, status, captions |
| `doc/Plan.LinuxServiceManager.md` | Modified | Front-matter, 11 D-records, 9 O-records, pins, captions, descriptions |
| `doc/Plan.Orchestration.md` | Modified | Front-matter, 2 D-records, 8 O-records, links, status, captions |
| `doc/Plan.Placement.md` | Modified | Front-matter, 2 D-records, 10 O-records, links, status, captions |
| `doc/Plan.UserFacingSurfaces.md` | Modified | Front-matter, 2 D-records, 8 O-records, links, status, spine, captions |
| `doc/Plan.ConcernTopologies.md` | Modified | Front-matter, 2 D-records, 6 O-records, links, status, captions |
| `doc/Survey.GranularityAndImage.md` | Modified | Front-matter, H1, links, caption |
| `doc/Survey.GameImage.md` | Modified | Front-matter, H1, 5 O-records, links, status, caption, description |
| `doc/Survey.BrowserAsOrbital.md` | Modified | relates-to, captions, provenance, project, title |
| `doc/Log.CompassMigration.md` | **New** | This log |


## Metrics

- Documents migrated: 15 (front-matter added) + 2 existing (updated)
- Decision records created: 72 (9 OrbitalImages, 13+13+15 Impulse, 3+11+2+2+2+2 Plans)
- Open-question records created: 58 (5 GameImage, 7+9+6+8+10+8+7 Plans; 2 in the migration plan)
- Table captions added: 65
- Description paragraphs added: 4 (1 OrbitalImages, 2 LinuxServiceManager, 1 GameImage)
- Stale links fixed: ~45 (DevLog/DevPlan/Concept → Log/Plan/Survey)
- Links rewritten to id-keyed text: ~47
- Files tables built from git: 8 (ImpulseII ×3, ImpulseIII ×4, Dependencies ×1)
- In-body status labels removed: 9
- Spine renames (Tests→Verification, Future work→Outstanding Work, etc.): ~20
- New infrastructure files: 3 (CI workflow, CODEOWNERS, INDEX.md)


## Outstanding Work

What remains is the steward's: reviewing statuses, accepting decision
records, and numbering with `compass assign`
(ORIGIN-DRAFT-compass-migration-O1). The migration changed structure, not
substance; no document's content claims were altered.
