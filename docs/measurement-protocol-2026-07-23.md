# Eval measurement protocol (2026-07-23)

Pre-registered protocol for the 30-good/100 campaign. Every headline claim about draft quality
follows these rules; anything else is a smoke check, not a measurement.

## Why (statistics)

Distinguishing 85% from 70% precision (one-sided, α=0.05, 80% power) needs **~50 drafted cases per
measurement**. At the observed ~20% draft rate that is a **250-300-case unseen cohort per headline
number**. A 100-case cohort yields ~20 drafts; the 95% CI on 15/20 spans ~0.53-0.89 — it cannot
detect any per-lever delta in the plan. The unseeded GPT-4o judge swings drafted count ±3-5 per
run: compare aggregates only, never single-run deltas.

## Rules

1. **Headline numbers come only from never-evaluated cohorts** of ≥250 cases, sampled via the
   `run_draft_eval_fresh*.apex` pattern with the exclusion list unioned from ALL
   `docs/eval-run-*.csv` files at sampling time. A cohort is consumed once for tuning decisions,
   then retired into the exclusion union.
2. **The pinned corpus2 100 is a regression smoke set only**: after each deploy, declines must not
   regress and fabricated-specific count must stay 0. Its good-rate is NOT reported as progress —
   it is overfit by construction (targeted fixes landed against it).
3. **Dual reporting**: every review reports strict (sendable only) AND lenient
   (sendable + minor_edits). The campaign target is lenient; strict catches wording-class
   regressions (e.g. persona slips).
4. **Review method**: two-pass blinded LLM review per `docs/eval-review-2026-07-21.md` (κ
   reported, disagreements adjudicated). For the final gate measurement: 2 eval runs, union
   labeling.
5. **One measurement per phase**, not per tweak — fresh cohorts are finite (~840 eligible cases
   remained after the 07-23 fresh200 sampling) and labeling is expensive.
6. **Gate measurement (end of campaign)**: one ≥250-case unseen cohort, 2-run union labeling.
   Pass = ≥28 good/100 lenient AND ≥85% precision among drafted AND 0 fabricated specifics AND
   declines never regressed vs the smoke set.

## Current baseline (frozen for comparison)

Unseen 300 (fresh + fresh200, 2026-07-23): 59 drafted, 34 good lenient (58% precision, ~11
good/100); clean channel 18/23 (78%); verify-flag precision ~55-68%. Bad-draft buckets per 100:
~5 not_kb_answerable, ~3 topical_but_wrong, ~2 ungrounded (all flagged).
