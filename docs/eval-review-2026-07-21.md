# Reviewer Labeling of the 32 corpus2 Drafts — Precision Findings (2026-07-22)

**Scope.** All 32 DRAFTED cases from the pinned-cohort eval `eval-pinned-2026-07-21-corpus2` (the coverage-push final run: 32/100 drafted, 8 clean + 24 gate-flagged under demote mode) were labeled by two independent, fully **blinded** LLM reviewer passes (reviewers saw only case text, draft, and the fed sources — never gateFlags/confidence/notes), with disagreements adjudicated by packet re-read. Rubric = the strict two-condition judge from `precision-plan-2026-07-20.md` (answers the *specific* problem + every concrete claim traceable to fed sources), verdict ladder from the 2026-07-16 round: `sendable / minor_edits / not_sendable`.

**Labels**: `docs/eval-drafts-reviewed-2026-07-21.csv` (this supersedes `eval-drafts-reviewed-2026-07-20b.csv` as the precision baseline). Filled eval sheet: `docs/eval-run-2026-07-21-corpus2-labeled.csv`.

## Reliability

- Pass1 vs pass2: **27/32 exact agreement (84%), Cohen's κ = 0.74** (substantial) — the labels are trustworthy.
- 3 escalations adjudicated by packet re-read (00033788 → not_sendable, 00033976 → minor_edits, 00034068 → not_sendable); recorded in the CSV's `adjudicated` column.

## Precision

| Cohort | n | sendable | minor_edits | not_sendable | strict | lenient (send+minor) |
|---|---|---|---|---|---|---|
| **all drafted** | 32 | 6 | 8 | 18 | 19% | **44%** |
| **clean (no gate flag)** | 8 | 3 | 4 | 1 | 38% | **88%** |
| **flagged (any gate)** | 24 | 3 | 4 | 17 | 13% | **29%** |
| verify-only | 17 | 1 | 3 | 13 | 6% | 24% |
| claims+verify | 5 | 1 | 1 | 3 | 20% | 40% |
| claims-only | 2 | 1 | 0 | 1 | 50% | 50% *(n=2, anecdotal)* |

not_sendable subclasses: 15 topical_but_wrong, 3 ungrounded (00034021, 00034050, 00034122). Baseline comparison: the 2026-07-20b round measured 52% precision on 21 drafts under the old config; today's **clean channel alone is 88%** — the gates reshaped the distribution exactly as designed, concentrating almost all the risk in the flagged channel.

## Gate vs reviewer (the demote-mode question)

| | reviewer: not_sendable | reviewer: ok |
|---|---|---|
| **gate-flagged** | 17 | 7 |
| **clean** | 1 | 7 |

- **Flag precision 71%** (17/24 flagged drafts are genuinely not sendable), **clean miss rate 13%** (1/8 — the adjudicated 00033788, an account/entitlement ask no KB reply can satisfy). Gate–reviewer κ = 0.47 (moderate).
- The verify gate is the strong signal: 76% of verify-only flags are correct rejections, and its stated reasons ("does not address the specific issue") match the reviewers' dominant subclass (topical_but_wrong) almost verbatim.

## Pre-registered decision rules → outcome

The rules were committed before results were read (plan file, Step 5):

1. *Flag type ≥50% not_sendable → recommend re-blocking that gate*: **TRIGGERED for verify** (76%) and claims+verify (60%); claims-only at exactly 50% is n=2 anecdotal.
2. *≥70% flagged-ok → gate is noise*: not triggered for any gate.
4. *Clean cohort >1/8 not_sendable → no go regardless*: **passed** (exactly 1/8, borderline).
5. *Production-go bar: lenient ≥80% overall AND ≥7/8 clean*: clean passes (7/8); **overall fails (44%) → NO production go in the current demote configuration.**

**Recommendation.** The verify gate is a good classifier and demote mode, as measured, ships ~17 bad drafts per 100 cases into reviewer queues to rescue ~7 good ones. Options, in order of the pre-registered rules:

- **(a) Re-block the verify gate** (config-only: `set_gate_mode_demote.apex` with `'block'`, or a per-gate mode if split later). Drafted falls to ~10/100 (8 clean + 2 claims-only) at ~80%+ precision — passes the go bar but surrenders most of the coverage win.
- **(b) Keep demote as reviewer triage** (the product decision locked on 07-21: drafts are always human-reviewed, reviewers filter). The data says the NEEDS-REVIEW banner is honest: a flagged draft is bad 71% of the time, a clean draft is good 88% of the time. Viable only if reviewers treat flagged drafts as "raw material," not near-final replies — worth a one-week reviewer-time check before committing.
- Either way the go/no-go bar per rule 5 is currently **no-go** for unsupervised confidence in the flagged channel; the clean channel alone is production-grade.

## Root causes in the 18 not_sendable (what to actually fix)

1. **The screenshot problem (~8 cases)** — error/symptom lives only in an unshown attachment (00033698, 00033772, 00033999, 00034033, 00034068, 00034112 …). Drafts guess; the strict rubric correctly fails them. This is `precision-plan-2026-07-20.md` Phase 3, still unaddressed — the single biggest lever. An "ask for the error text first" reply template would convert most of these into useful (if modest) drafts.
2. **Retrieval misses with the right doc in-corpus (4 confirmed by nomination check)**: 00033772 → *Fixing Template Errors After Template Migration*; 00034155 → *Manage User Access* (S-Sign license assignment via Installed Packages); 00034062 → *Connecting S-Docs to Your Customer Records* (missing lookup ≈ the SSIC_Policy__c error); 00033999 → *Rich Text Field Formatting Considerations* (literal `<p>` tags). The answer existed; the pool fed a neighboring doc instead.
3. **Corpus-quality bug — ingestion strips code-block markup (NEW, actionable)**: the DOCX table-syntax doc and the *Format and Summarize a Related List* doc both carry gutted code examples (S-Docs' XML-ish `<column>`/lineitems tags sanitized away, leaving `[{{! ]` fragments). Directly caused ungrounded 00034122 and degraded 00034068. Fix in `HelpSdocsConnector` HTML sanitization (preserve text inside code/pre blocks), re-ingest affected docs. Also: GitBook "Agent Instructions" trailers are still embedded in fed bodies (known issue) and waste grounding budget.
4. **Fabricated specifics that slipped the claim check (2)**: 00034050 invented "150 per year / no reset date" (the number 150 is in-source, the periodicity is not — token-level checking can't catch it); 00034021 invented SOQL `AS`-aliasing on plain fields. Both were verify-flagged, so the LLM gate caught what the deterministic one couldn't.

## Limits

- Grounding universe = fed sources only; `should_have_drafted=no` (14/32) means *no fed doc answered* — corpus-wide answerability was only spot-checked via the nomination mechanism.
- Reviewer notes cross-tab uses the detail JSON's 300-char notes excerpt (the dry-run eval writes no Case fields, so full `AI_Draft_Notes__c` doesn't exist for these runs).
- n=2 for claims-only; treat that row as anecdote.
- LLM reviewers, not humans — κ=0.74 inter-rater agreement bounds but does not eliminate shared-model bias; the strict rubric deliberately biases harsh ("when uncertain, choose the harsher").
