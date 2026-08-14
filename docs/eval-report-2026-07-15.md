# Draft Pipeline Batch Evaluation — 100 Historical Cases (2026-07-15)

A dry-run of the full production draft pipeline (`SupportDraftOrchestrator.orchestrate()`, exact
flow-parity field mapping: Subject / Description / Product_List__c) over 100 randomly sampled
historical Email-origin cases. **No Case was modified and no draft email was created** — the run's
only write was the per-case CSV report (`docs/eval-run-2026-07-15.csv`, the raw data behind every
number here).

## Run metadata

| | |
|---|---|
| Org / runner | vscodeOrg, `DraftEvalBatchJob` (chained Queueable, 5 cases/execution, 20 executions) |
| Cohort | Random sample (Fisher-Yates) of 100 from a 496-case pool: `Origin = 'Email'`, non-blank Subject + Description, `AI_Draft_Status__c = null`, created in the last 365 days, `[SANDBOX TEST]` internal test emails excluded |
| Cohort products | S-Docs 73, S-Sign 9, S-Docs;S-Sign 7, blank 11 |
| Live config at run time | fusion `rrf`, embeddings ON, query distillation ON, goodScore 0.45, mediumScore 0.30, drafting floor 0.45 (default) |
| Model | `sfdc_ai__DefaultGPT4Omni` (generation + distillation), ada-002 (embeddings) |
| Reliability | **100/100 cases processed, 0 errors, no chain failures** |

## Headline

**14 of 100 cases (14%) produced a customer-ready draft.** The other 86 declined safely: 79 low
confidence (evidence below the drafting bar), 7 no candidates at all — and every one of those 7 is
explained by a single product-filter defect (see Finding below). Excluding the defect-affected
cases, the effective draft rate is **14/93 = 15.1%**. Nothing escalated, nothing errored, nothing
drafted ungrounded.

| Status | Count | % | Meaning |
|---|---|---|---|
| DRAFTED | 14 | 14% | Grounded draft produced, ready for agent review |
| NO_DRAFT_LOW_CONFIDENCE | 79 | 79% | Retrieval/model evidence below the bar — declined, routed to a human |
| NO_DRAFT_NO_MATCH | 7 | 7% | Zero candidates retrieved (all 7 = product-filter defect) |
| ESCALATE / UNGROUNDED / MODEL_ERROR / EXCLUDED / ERROR | 0 | 0% | — |

## Confidence

| Confidence | All 100 | Drafted (14) | Mean topScore |
|---|---|---|---|
| HIGH | 5 | 5 | 0.61 |
| MEDIUM | 2 | 2 | 0.48 |
| LOW | 86 | 7 | 0.36 |
| NONE | 7 | 0 | 0.00 |

- **Ordinal average confidence** (HIGH=3 / MEDIUM=2 / LOW=1 / NONE=0): **1.05** across all 100;
  **2.86 among HIGH/MEDIUM drafts**. Half the drafted set (7/14) carries a LOW tag — the
  clamp-to-lower rule (final tag = min(model, retrieval)) is deliberately conservative, so a LOW
  drafted case means "review with extra care," not "bad draft."
- **Numeric retrieval topScore** (new `retrievalTopScore` audit field): mean **0.35**, median
  **0.33**, range 0.00–0.875. Drafted cases average **0.60** vs **0.34** for low-confidence
  declines — clean separation between what drafts and what doesn't.

Score distribution against the live thresholds:

| topScore band | Cases | Note |
|---|---|---|
| < 0.30 (below mediumScore) | 45 | never draftable |
| 0.30 – 0.45 (below drafting floor) | 23 | never draftable |
| 0.45 – 0.60 | 24 | 6 drafted; most others were honest model declines |
| 0.60 – 0.75 | 3 | 3 drafted |
| ≥ 0.75 | 5 | 5 drafted or declined-with-reason (see below) |

## Finding: multi-product cases can never draft (production defect)

All 7 `NO_DRAFT_NO_MATCH` cases — and only those — have `Product_List__c = 'S-Docs;S-Sign'`. The
flow passes that multi-select value verbatim as the retrieval product filter, but every corpus doc
is tagged `S-Docs` *or* `S-Sign`, so the filter matches nothing and retrieval returns zero
candidates (topScore 0.0, distillation fires and can't help). **This affects the live pipeline
identically**: any Email case tagged with both products gets `NO_DRAFT_NO_MATCH` regardless of how
good the corpus is. Fix candidates: split the multi-select into per-product retrieval passes, or
treat a multi-value product as "search both" (the existing blank-product behavior). ~7% of the
sampled caseload is affected.

## What declined, and why it's the right behavior

The 5 highest-scoring non-drafted cases (topScore 0.54–0.76) were all **explicit model declines**:
retrieval surfaced a related doc, and the model judged it didn't actually answer the customer's
specific question (e.g. mailmerge-over-500 case retrieved the job-splitter doc but the doc didn't
address the customer's error; the CSP frame-ancestors case retrieved general LWC docs). Each
decline is capped at LOW and carries the model's reason in the notes. This is the anti-hallucination
posture working: the system writes only when the doc genuinely answers, and says why when it won't.

## Query distillation impact

| Distillation | Cases | Drafted |
|---|---|---|
| Not fired (first pass ≥ trigger) | 19 | 7 |
| Fired, distilled query won | 13 | 7 |
| Fired, original pass kept | 68 | 0 |

**Distillation doubled the draft yield**: 7 of the 14 drafts exist only because the LLM-distilled
query decisively beat the raw case text. The 68 "tried, kept original" cases were already
low-scoring and stayed low — the accept-margin gate (D28 hardening) correctly stopped weak
distilled passes from flipping outcomes. Caveat: the distiller is sampled (non-deterministic), so
individual near-threshold cases can flip between runs; the aggregate rates are the stable signal.

## Per-product

| Product | Cases | Drafted | Draft rate | Mean topScore |
|---|---|---|---|---|
| S-Docs | 73 | 11 | 15% | 0.39 |
| S-Sign | 9 | 1 | 11% | 0.44 |
| (blank → searches both) | 11 | 2 | 18% | 0.29 |
| S-Docs;S-Sign | 7 | 0 | 0% | 0.00 (product-filter defect) |

## Drafted set quality signals

- Average draft length **1,439 chars** (~200–250 words) — full replies, not stubs.
- Average **1.9 source docs** fed per draft; every draft carries its source ids for agent audit.
- Example (00033813, "Error editing any template", HIGH, topScore 0.70): 1,049-char grounded reply
  drafted from the template-editor fix doc.

## Timing

Mean **4.2s** per case, median 3.7s, p90 6.4s, max 18.8s; ~7 minutes of pipeline compute for the
full run. Per-case cost: 1–3 Models API calls (embedding always; distillation on 81 cases;
generation only on the 19 + 13 cases that reached the draft gate).

## Caveats

- **Dry-run parity**: the harness calls the same entry point with the same three inputs the flow
  passes; the flow's stamp/publish steps were the only things not exercised.
- **Sampling**: random over a 365-day window; recent months are somewhat overrepresented because
  the 500-case candidate pool is recency-ordered before shuffling.
- **Distillation variance**: re-running the same 100 cases will move individual near-threshold
  outcomes (documented in D22/D28); aggregates are stable.
- **The 14% is a floor, not a ceiling**: 7% of the sample is recoverable by the multi-product fix
  alone, and the decline notes identify concrete corpus gaps (mailmerge >500 limits, PDF rendering
  engine, CSP configuration, table formatting) that would raise the drafted rate as docs are added.

---
*Raw data: `docs/eval-run-2026-07-15.csv` (one row per case: status, confidence, topScore,
distillation outcome, sources, draft/notes excerpts, timing). Harness: `DraftEvalBatchJob` +
`scripts/apex/run_draft_eval.apex` / `fetch_draft_eval.apex` (D29).*
