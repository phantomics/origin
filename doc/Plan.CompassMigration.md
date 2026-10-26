---
id:            ORIGIN-0001
title:         "Compass Migration: Development Plan"
genre:         Plan
scope:         project
project:       Origin
language:      en
status:        Implemented
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-10-25
provenance:
  assistant:   opencode
relates-to:
  - ORIGIN-DRAFT-browser-as-orbital
decisions:
  - ORIGIN-D1
  - ORIGIN-D2
  - ORIGIN-D3
  - ORIGIN-D4
  - ORIGIN-D5
  - ORIGIN-D6
  - ORIGIN-D7
  - ORIGIN-D8
  - ORIGIN-D9
open-questions:
  - ORIGIN-O6
  - ORIGIN-O7
cites:
  - title:    Compass Standard v0.4.0
    locator:  COMPASS-0001
    external: true
---

# Compass Migration: Development Plan

This plan brings Origin's documentation into conformance with version 0.4.0
of the Compass standard, as checked by version 0.2 of its toolchain. It
proceeds in three phases: a clean baseline with the infrastructure the
standard now expects; front-matter and link fixups on every document; and
deeper conformance in the bodies (decision records, open-question records,
pinned code references, Log spines, and accessibility markup). It changes
how the documents are shaped, identified, and linked, not what they say
about the code. The model is Classic's migration
([CLASSIC-0032](../../classic/doc/Plan.CompassMigration.md)
and [CLASSIC-0036](../../classic/doc/Log.CompassMigration.md)), adapted
to Origin's specific state.

## Problem

Origin adopted Compass infrastructure early: `compass.sexp`, `.mailmap`,
and `doc/REGISTRY.sexp` are in place (commit `7ef2f48`), and files were
renamed to genre prefixes (commit `4bbea31`). One document,
[ORIGIN-DRAFT-browser-as-orbital](Survey.BrowserAsOrbital.md), carries
full Compass front-matter and checks clean. The remaining 15 documents have
no front-matter and are skipped by `compass check --skip-unmarked`.

`compass check` without `--skip-unmarked` reports **15 errors**, all
`fm/present`. Once front-matter is added, further issues will surface:

- **Broken links.** About 45 references still name `DevLog.*`, `DevPlan.*`,
  or `Concept.*` files that commit `4bbea31` renamed. They appear across 14
  documents.
- **Decisions are prose, not records.** About 70 numbered decisions are
  written as bold-lead lists or `### N.` headings across the five Logs and
  three Plans. Four Plans have no `## Settled Decisions` section; their
  settled points sit in prose.
- **Open questions are numbered lists, not records.** About 60, across seven
  Plans and one Survey.
- **Unpinned code references.** The Logs name paths without revisions. Some
  paths are Lexter files (`src/origin-image.lisp`,
  `src/origin-impulse.lisp`, `src/packages-origin.lisp`) needing a
  `LEXTER:` prefix. `Plan.LinuxServiceManager.md` uses bare line-number
  references.
- **Accessibility.** None of the roughly 54 tables in the corpus has a
  `Table:` caption in the fixed form. The browser Survey uses
  `**Table N. …**` rather than `Table:`.
- **Shape.** Two Surveys have pre-migration H1s ("Concept:"/"Conceptual
  Foundations:") and lowercase spine headings. Thirteen documents carry
  in-body `**Status:**` lines that would compete with front-matter status.

The corpus has no generated `INDEX.md`, no CI workflow, and no
`CODEOWNERS`. `AGENTS.md` still instructs `--skip-unmarked`.

## Goals

- `compass check`, without `--skip-unmarked`, reports no errors.
- `compass check --federation` reports no errors in references into the
  `COMPASS`, `CLASSIC`, and `LEXTER` corpora.
- Every document under `doc/` has §7 front-matter, a provisional identifier,
  and id-keyed links.
- Decisions and open questions are ADR-shaped records citable corpus-wide.
- Code references in Logs and Plans are commit-pinned.
- A ledger, a generated index, CI, and code owners keep the corpus
  conforming after the migration.

## Settled Decisions

### ORIGIN-D1 — Keep ORIGIN-O1 through ORIGIN-O5 canonical

**Status:** Accepted

**Context:** The ledger allocates ORIGIN-O1 through ORIGIN-O5 as canonical numbers for
the open questions in `Survey.BrowserAsOrbital.md`, which is still
`Draft`. The standard says canonical numbers are assigned at acceptance,
but the ledger is append-only and the numbers are already allocated.

**Decision:** Keep them canonical. The Survey already checks clean with
them. The next allocation is O6.

**Alternatives:**
- Convert to provisional `ORIGIN-DRAFT-browser-as-orbital-O1` through
  `-O5`. Rejected: the numbers stay allocated in the ledger regardless, so
  renaming them creates orphaned entries with no benefit.

### ORIGIN-D2 — Every other record gets a per-document provisional identifier

**Status:** Accepted

**Context:** About 130 decisions and open questions across 15 documents
need identifiers. None has been accepted.

**Decision:** Each record takes a provisional identifier formed from its
host document's slug: `ORIGIN-DRAFT-<slug>-D<n>` or `-O<n>`, numbering
from 1 within each document. `compass assign` gives canonical numbers when
the steward accepts each document.

**Alternatives:**
- Number them canonically now. Rejected: canonical numbers are assigned at
  acceptance by the steward (§13), and these documents are drafts.

### ORIGIN-D3 — Every migrated document is status Draft

**Status:** Accepted

**Context:** An assistant never sets an authoritative status (`Accepted`,
`Implemented`, `Design-Record`, `Current`) or `approved-by` (§6). Every
migrated document needs a status from its genre's vocabulary. The five Logs
record work that was built and committed; the status says only that the
migration has not been reviewed.

**Decision:** Every document takes `status: Draft`. Decision records take
`Proposed`. The steward then sets `Implemented` on the Logs, and `Current`
or `Accepted` where a document warrants it, after reviewing it.

**Alternatives:**
- `Implemented` on the Logs during migration. Rejected: `Implemented` makes
  a Log eligible for `compass assign`, and that eligibility is the
  steward's to grant.

### ORIGIN-D4 — Multi-phase Logs keep their Phase sections

**Status:** Accepted

**Context:** The three Impulse Logs each record several phases, already
structured as `## Phase N — …` sections. Compass permits phased Logs with
the skeleton repeated at H3.

**Decision:** Keep the `## Phase N —` structure. Each phase is pinned to
its own commit.

**Alternatives:**
- Convert to dated `## Update <date> — <title>` sections (as Classic does
  under CLASSIC-D100). Rejected: the Phase headings are the established
  structure and the Compass Log shape explicitly permits them.

### ORIGIN-D5 — Decision records add no content

**Status:** Accepted

**Context:** About 70 numbered decisions need to become ADR-shaped records.
Many state their alternatives in prose; some do not.

**Decision:** Context, Decision, and Alternatives are drawn only from each
document's existing text. Where the text names no alternative, the field
says "None recorded." Explanatory prose that does not fit the three fields
stays after them. Any statement added to a historical Log is marked
`*Migration note (<date>):*`.

**Alternatives:**
- Reconstruct missing alternatives from the code and history. Rejected: it
  would put claims in a historical record that its author never made.

### ORIGIN-D6 — Code references pin to each Log's work commits

**Status:** Accepted

**Context:** A Log's code references must be commit-pinned (§9). Origin's
Logs name files as they stood when the work was done. Some paths are Lexter
files that live in a different repository.

**Decision:** Each Log's references are pinned to the commit that holds the
work it records, with the paths as they were at that commit. Lexter files
are prefixed `LEXTER:` and pinned to Lexter commits. Files-table paths
keep the names the files had when they were committed.

Table: The commits each Log's code references are pinned to.

| Log | Origin commits | Lexter commits |
|---|---|---|
| `Log.OrbitalImages.md` | `ab349e7` | `c8acd7c` |
| `Log.ImpulseI.md` | `ada812e`, `d9ac637`, `2503ee0` | `a9a426c` (Phase 3 launcher integration) |
| `Log.ImpulseII.md` | `3552924`, `dff5487`, `13cfe9f` | — |
| `Log.ImpulseIII.md` | `3dcb7ab`, `cf288c4`, `2ba22c3`, `9a32069` | `8000d83` (Phase 7), `1f07ee8` (Phase 9 handoff) |
| `Log.Dependencies.md` | `2622b17` | — |

The bare line-number references in `Plan.LinuxServiceManager.md` become
symbol-pinned references (e.g.
`src/managed-process.lisp:%stop-process-image@57e8988`).

**Alternatives:**
- Pin to the current `HEAD` and update the paths. Rejected: it rewrites
  history.

### ORIGIN-D7 — Links are fixed; stale content is not refreshed

**Status:** Accepted

**Context:** About 45 links name files by their pre-rename paths. In-body
`**Status:**` lines would compete with front-matter status.

**Decision:** Every link from one document to another becomes an id-keyed
Markdown link. In-body `**Status:**` labels are removed; where the status
paragraph carries substantive content (dependencies, framing, tier
descriptions), the content is kept as an opening paragraph without the
label. `**Date:**` lines are kept (they record when the work or idea was
dated by its author, which can differ from Git's dates). `created` and
`updated` are omitted from front-matter and derived from Git. Stale
content is not refreshed.

**Alternatives:**
- Refresh stale content in the same effort. Rejected: it multiplies the
  size of the change and mixes structural edits with content edits.

### ORIGIN-D8 — CI and code owners mirror Classic

**Status:** Accepted

**Context:** Classic enforces its standard with a CI workflow that builds
the toolchain at a pinned revision and checks the corpus against the base
branch, and a CODEOWNERS entry that requires the steward's approval for
ledger changes.

**Decision:** Origin adopts the same: `.github/workflows/compass-check.yml`
at the same pinned `COMPASS_REV` (`9a6ab23`), and `.github/CODEOWNERS`
assigning `/doc/REGISTRY.sexp` to the steward. Branch protection is set by
the steward in GitHub settings.

**Alternatives:**
- No CI for now. Rejected: the uniqueness of numbers depends on a check
  that cannot be bypassed.

### ORIGIN-D9 — Provenance is assistant: opencode

**Status:** Accepted

**Context:** Classic's migration documents record `assistant: opencode`.
Origin's browser Survey records `assistant: claude`.

**Decision:** Every migrated document, including the browser Survey when it
is edited in this migration (for `Table:` captions and `relates-to`), uses
`assistant: opencode` for consistency with Classic.

**Alternatives:**
- Keep `claude` on the browser Survey. Rejected: a corpus should use one
  provenance convention; `opencode` names the harness, which is consistent
  across models.

## Phase 1 — Clean baseline

1. **Refresh `AGENTS.md`** from the current Compass snippet: add sentences
   on `compass assign`, the ledger, and the index; remove the
   `--skip-unmarked` instruction (after Phase 2 lands); update the
   migration note.
2. **Add CI and code owners**
   (ORIGIN-D8).
   `.github/workflows/compass-check.yml` and `.github/CODEOWNERS`.
3. **Generate the index** with `compass index`.
4. **Gate:** `compass check --skip-unmarked` reports no errors, and
   `compass index --check` passes.

## Phase 2 — Front-matter on every document

1. **Add front-matter** to the 15 unmarked documents, following each
   genre's template:

   Table: Front-matter to add to each document, with genre, scope, and component.

   | Document | Genre | Scope | Component |
   |---|---|---|---|
   | `Eval.ControlVocabulary.PriorArt.md` | Eval (prior-art) | project | impulse |
   | `Log.OrbitalImages.md` | Log | project | core |
   | `Log.ImpulseI.md` | Log | project | impulse |
   | `Log.ImpulseII.md` | Log | project | impulse |
   | `Log.ImpulseIII.md` | Log | project | impulse |
   | `Log.Dependencies.md` | Log | project | core |
   | `Plan.ControlVocabulary.md` | Plan | project | impulse |
   | `Plan.ForeignOrbitals.md` | Plan | project | tether |
   | `Plan.LinuxServiceManager.md` | Plan | project | — |
   | `Plan.Orchestration.md` | Plan | project | — |
   | `Plan.Placement.md` | Plan | project | — |
   | `Plan.UserFacingSurfaces.md` | Plan | project | — |
   | `Plan.ConcernTopologies.md` | Plan | project | — |
   | `Survey.GranularityAndImage.md` | Survey | project | — |
   | `Survey.GameImage.md` | Survey | project | — |

   Each takes a provisional `id`, `status: Draft`
   (ORIGIN-D3), `project: Origin`,
   `language: en`, and `provenance: { assistant: opencode }`
   (ORIGIN-D9). `relates-to`
   is populated where documents cite each other. `created` and `updated`
   are omitted; the toolchain derives them from Git
   (ORIGIN-D7).

2. **Fix stale links** (~45 across 14 documents). Every link from one
   document to another becomes an id-keyed Markdown link to the document's
   current name (ORIGIN-D7).
3. **Remove in-body `**Status:**` lines**; keep `**Date:**` lines
   (ORIGIN-D7).
4. **Reshape the two older Surveys.** `Survey.GranularityAndImage.md` and
   `Survey.GameImage.md`: set H1 to `<Topic>: Survey`, capitalise spine
   headings, and turn their open-question numbered lists into
   `ORIGIN-DRAFT-<slug>-O<n>` records.
5. **Fill the browser Survey's `relates-to`** now that every document has
   an id. Update its `Table:` captions from `**Table N. …**` to the
   `Table:` form. Update its provenance to `opencode`
   (ORIGIN-D9).
6. **Gate:** `compass check` without `--skip-unmarked` reports no errors;
   `AGENTS.md` drops the `--skip-unmarked` instruction; the index is
   regenerated.

## Phase 3 — Deeper conformance

Committed in batches by component, each batch checked before the next.

1. **Decision records**
   (ORIGIN-D5). Each becomes
   `### ORIGIN-DRAFT-<slug>-D<n> — <title>`, mirrored into `decisions:`,
   with status `Proposed`.
2. **Open-question records.** Each becomes
   `### ORIGIN-DRAFT-<slug>-O<n> — <title>`, mirrored into
   `open-questions:`.
3. **Pinned code references**
   (ORIGIN-D6). Each Log's
   paths become `path:symbol@revision`, pinned to the commits in the table
   above. Lexter paths take the `LEXTER:` prefix. The bare line references
   in `Plan.LinuxServiceManager.md` become symbol-pinned.
4. **Log spines** (§14). Tests becomes Verification; Future work becomes
   Outstanding Work; Files tables take the File, Action, and Description
   columns with a caption. Missing spine sections are added without new
   claims.
5. **Accessibility** (§12). A `Table:` caption paragraph before every table
   in the corpus (about 54 tables). No diagrams exist in the unmarked
   documents.
6. **Gate:** `compass check --federation` reports no errors; the index is
   current; each batch is reviewed with `compass-review`.

Table: Proposed Phase 3 batches.

| Batch | Documents |
|---|---|
| Core Logs | `Log.OrbitalImages.md`, `Log.Dependencies.md` |
| Impulse Logs | `Log.ImpulseI.md`, `Log.ImpulseII.md`, `Log.ImpulseIII.md` |
| Plans | `Plan.ControlVocabulary.md`, `Plan.ForeignOrbitals.md`, `Plan.LinuxServiceManager.md`, `Plan.Orchestration.md`, `Plan.Placement.md`, `Plan.UserFacingSurfaces.md`, `Plan.ConcernTopologies.md` |
| Surveys and Eval | `Survey.GranularityAndImage.md`, `Survey.GameImage.md`, `Eval.ControlVocabulary.PriorArt.md` |

## Scope and Non-Goals

Outside this plan:

- Refreshing stale content in any document. The migration changes structure,
  not substance.
- The steward's review of statuses, acceptance of decision records, and
  `compass assign`.
- The Lexter repository's migration, which is planned separately.

## Tensions and Risks

- **The local toolchain is a dirty build** (`4ec6121-dirty`) and CI will
  build `9a6ab23`. Gates should be checked with both builds, as Classic did
  (CLASSIC-D111).
- **Accessibility and section shapes are not checked by the toolchain.**
  Phase 3's accessibility work and spine reshaping are verified by review,
  not by `compass check`.
- **Lexter work commits still need identification.** The Lexter commits for
  `Log.OrbitalImages.md` and `Log.ImpulseI.md` Phase 3 are to be confirmed
  from Lexter's history.
- **Decision extraction is judgment.** Splitting prose into Context,
  Decision, and Alternatives can change emphasis. Each converted document
  keeps its original wording where it can.
- **Many records to accept.** The Logs and Plans yield about 130 records,
  all `Proposed`. Accepting them a batch at a time keeps the backlog
  manageable.

## Open Questions

### ORIGIN-O6 — Which documents are numbered first

Once the migration lands, every document and record has a provisional
identifier. Should the steward number the corpus at once, in path order, or
document by document as each is reviewed and accepted?

### ORIGIN-O7 — A compiled README

Compass lets a repository README be compiled from a template that includes
sections of the corpus by identifier (§10). Origin's README combines a
getting-started guide, an API reference, and an init-system section. Should
it be compiled once the compiler exists, or stay hand-written with links to
the documents?

## Prior Art

Table: Prior work in the federation and what this plan draws from each.

| System | What to draw from |
|---|---|
| [COMPASS-0001](../../compass/Compass.md) | The standard being conformed to (version 0.4.0) |
| [COMPASS-0004](../../compass/doc/Plan.Toolchain.md) | The plan governing what the toolchain checks and the ledger discipline |
| Classic's migration ([CLASSIC-0032](../../classic/doc/Plan.CompassMigration.md), [CLASSIC-0036](../../classic/doc/Log.CompassMigration.md)) | The three-phase structure, the D-record conventions (CLASSIC-D92 through CLASSIC-D102), the gate discipline, and the CI/CODEOWNERS pattern |
| Origin commit `7ef2f48` | The `.mailmap` and ledger already in place |
| Origin commit `4bbea31` | The genre-prefix renames already done |

## Roadmap

1. Phase 0: the plan is clean and reviewed.
2. Phase 1: the baseline — CI, code owners, index, refreshed agent guide.
3. Phase 2: front-matter on every document; links fixed; the two Surveys
   reshaped; the browser Survey's `relates-to` and captions.
4. Phase 3, by batch: core Logs; Impulse Logs; Plans; Surveys and Eval.
5. Phase 4: `Log.CompassMigration.md`, recording the work.
6. The steward reviews statuses, accepts records, and numbers with
   `compass assign`
   (ORIGIN-O6).
