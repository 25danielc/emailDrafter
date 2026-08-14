# Phase-1 Fresh-Cohort Measurement — fresh250 (2026-07-23)

**Cohort**: 250 never-evaluated cases (554-id exclusion union of all prior eval runs; sampler
`scripts/apex/run_draft_eval_fresh4.apex`, pool 931 eligible). Run label
`eval-fresh250-2026-07-23r2` (first attempt died on a regex blow-up in the new structural gate —
fixed same-day: scan capped at 3,000 chars, apostrophe-quote branch removed). Pipeline config:
Phase-1 final (structural pre-decline ON with widened veto; verify second vote OFF; persona
scrub + prompt rule 11; all pre-existing gates unchanged; demote mode, floor 0.45).

**Review method**: 8 blinded packets (case text + draft + fed sources only), two independent LLM
passes, strict two-condition rubric, harsher-when-uncertain. **Agreement 40/44 exact (91%),
κ = 0.86** — all 4 disagreements were adjacent sendable-vs-minor_edits and were adjudicated to
minor_edits per the harsher rule; zero good-vs-bad disagreements. Labels:
`docs/eval-drafts-reviewed-2026-07-23-fresh250.csv`.

## Results

250 cases → **44 drafted (17.6%), 0 errors**; 4 NO_DRAFT_UNGROUNDED blocks; 3 structural declines.

| | n | sendable | minor_edits | not_sendable | strict | lenient |
|---|---|---|---|---|---|---|
| **all drafted** | 44 | 11 | 18 | 15 | 25% | **66%** |
| clean (no flag) | 21 | 9 | 7 | 5 | 43% | **76%** |
| verify-flagged | 22 | 1 | 11 | 10 | 5% | 55% |
| claims-flagged | 1 | 1 | 0 | 0 | — | 100% |

**Good-yield: 11.6/100 cases (lenient).**

not_sendable subclasses: **8 not_kb_answerable** (screenshot/entitlement/org-investigation cases
whose text carries enough substance to pass the structural veto), **4 ungrounded** (2 clean —
00033067, 00033363: unsupported causal/capability claims that reuse source vocabulary, so no
concrete token for the claim check and the judge approved), **3 topical_but_wrong** (wrong
product/scenario — the Phase-2 target bucket).

## vs pre-Phase-1 unseen baseline (300 cases, 07-23)

| | pre-Phase-1 | post-Phase-1 |
|---|---|---|
| good/100 (lenient) | ~11.3 | 11.6 |
| precision (lenient) | 58% | 66% |
| clean-channel good | 78% | 76% |
| verify-flag precision (flagged actually bad) | ~55-68% (wide) | 45% |
| persona slips among good drafts | ~17% | **0/44** |

**Honest statistical caveat**: at 44 drafted, the 95% CI on 66% spans roughly ±14 points — the
+8-point precision move is directionally positive but NOT statistically conclusive against 58%.
The persona result (0/44 vs ~10/59) IS conclusive. The second-vote disable and structural-veto
iterations were driven by the pinned smoke, not this cohort.

## What this says about the remaining gap to 30 good/100 @ ≥85%

- Yield is unchanged at ~11-12/100 — as the honest-eval predicted, **code precision work does not
  create yield**. The yield levers remain the user's gap-topic authoring (probe harness ready)
  and OCR.
- To reach ≥85% precision at ~35 drafted, bad drafts must fall from ~6/100 to ~2/100. The bucket
  order: not_kb_answerable 8 (needs OCR/attachment awareness or a smarter structural signal —
  text-pattern vetoes spare substance-bearing but unanswerable cases by design), topical 3
  (Phase-2 goal-match), clean ungrounded 2 (causal claims without concrete tokens — the known
  judge-miss residual; a claim-check extension to unsupported causal assertions is the only
  deterministic lever).
- The verify flag remains a coin flip on fresh topics (45% precision) — demote-mode reviewer
  triage is carrying real weight; any Phase-2 addition to the judge prompt must be measured
  against this baseline.
