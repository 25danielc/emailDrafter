# Decline Diagnosis — Why 79/100 Cases Didn't Draft (2026-07-16)

Follow-up to `eval-report-2026-07-15.md`. Question under investigation: **are the 79 low-confidence
declines scoring false negatives, or a genuine knowledge gap — and is the confidence equation
wrong?** Method: re-probed 56 declines + all 14 drafted cases with a read-only diagnostic that dumps
the per-candidate score internals production discards (lexical / semantic / content per doc, plus
the full SOSL pool), then ground-truth labeled every probed case against the full 311-doc corpus
(parallel reviewer agents; all retrieval-blame labels mechanically re-verified against probe data).
Per-case labels: `eval-diagnosis-labels-2026-07-16.csv`. No production code was changed.

## The answer in one paragraph

**The confidence equation is not the main story — the caseload is.** Extrapolated across the 79
declines: **~45% (35 cases) were never answerable by any KB** (billing/licensing actions, org-specific
investigations, screenshots-only errors, spam, meeting invites, and auto-reply mail loops), and
**~39% (31 cases) are genuine corpus gaps** — real, doc-able product questions that none of the 311
docs answers. Retrieval/scoring false negatives account for **~16% (13 cases)**: an answering doc
existed in the search pool but was under-scored, hidden behind the rank-1 read, cut by selection, or
(1 case) never pooled. The equation has two real, measured defects, but fixing them recovers at most
~13 drafts — while the labeling shows the bigger risk runs the other way: aggressive score inflation
would mostly promote *topically-related-but-wrong* docs, which is exactly what produced the 2
confirmed false positives among the 14 drafted.

## Attribution across the 79 declines

| Label | Meaning | Measured (56 labeled) | Extrapolated to 79* | % |
|---|---|---|---|---|
| A1 | Answering doc scored ≥0.45 but wasn't RRF rank-1 (rank-1 read hid it) | 2 | 2 | 3% |
| A2 | Answering doc returned but content under-scored (<0.45) | 5 | ~6.5 | 8% |
| A3 | Answering doc in pool but cut before candidates | 2 | 2 | 3% |
| B | Answering doc exists but never entered the SOSL pool | 1 | ~2.5 | 3% |
| **A+B: retrieval/scoring false negatives** | | **10** | **~13** | **~16%** |
| C | Genuine corpus gap (doc-able question, no doc exists) | 23 | ~31 | 39% |
| D | Not KB-answerable — correct decline | 23 | ~35 | 45% |

\* Deep-low band (<0.30) sampled 15 of 38, so its labels extrapolate ×2.5; the other strata were
labeled exhaustively. CI note: with 15/38 sampled, each deep-low percentage carries roughly ±12pt
at 95% — the C/D split there is directionally solid, not precise.

## Is the equation wrong? Two measured defects — with counterfactuals

**Defect 1 — topScore reads the wrong doc (A1/A3).** `topScore` is the content score of the
*RRF-rank-1* candidate, but RRF ranks on raw lexical+semantic, not content — so a stronger-content
doc at rank 2+ never sets confidence. Counterfactual (CF-1) on the 38 probed below-floor cases:
reading **content-max across candidates** would push only **5** over the 0.45 floor. Real, cheap to
fix, small.

**Defect 2 — the semantic rescale band zeroes related docs (A2).** Live band 0.76–0.86 maps raw
ada-002 cosine <0.76 to 0; with the semantic-led blend (weight 0.55) a correct-but-differently-worded
doc collapses to `0.75 × lexical` and lands just under the floor (measured example: the Usage-Metrics
doc answering "how many envelopes have we used" sat at **rank 1 with content 0.24** — lexical 0.32,
semantic 0.00). Counterfactuals on the same 38 cases: widening simFloor to 0.72 lifts **17** over
the floor; to 0.70 lifts **21**; pure-lexical scoring lifts **11**.

**Why not just widen the band: the labels say most of those 17–21 crossings are C/D cases** —
wrong-doc promotions that would spend generation calls and manufacture false positives (the 2
confirmed FPs below are precisely "topical match, wrong answer" drafts). The safe reading: fix
defect 1 outright; re-measure the band on the current corpus (D19's measurement predates the
help.sdocs ingestion) rather than blanket-widening it.

**Confidence should NOT "be zero"** — the score separates well in aggregate (drafted cases mean
0.60 vs declines 0.34), and the floor is doing its job: of the 18 cases that *did* cross it and
reached the model, the model's decline was correct in 15.

## The model-decline gate is well calibrated (15/18 correct)

The 18 declines with score ≥0.45 were audited individually: in 15, the retrieved docs genuinely
did not answer the customer's specific question (score came from topical overlap) and drafting
would have been ungrounded. Only **3 were over-conservative** (00034166 — the rank-1 doc IS the
iframe-block fix; 00034110 — install doc answers the free-tier download blocker; 00033871 — DOCX
merge-syntax docs at ranks 2–3 sufficed). The LLM gate is the system's best defense and should not
be loosened.

## False positives among the 14 drafted: 2 confirmed

Full-draft audit (regenerated; caveat — generation is sampled, so these are fresh artifacts):
**1 sendable as-is, 10 sendable with minor edits, 2 not sendable, 1 regen-declined.**

- **00033813** — customer pasted a specific missing-field SOQL error; draft confidently misdiagnosed
  it as the unrelated stuck-error-flag fix. Wrong repair path.
- **00033797** — a billing thread asking S-Docs to *issue* a temporary license key; draft explained
  how to paste a key the customer doesn't have. Topical match, wrong question.
- 00034046 regen-declined — the original DRAFTED/HIGH was the unstable side of the known
  score-straddle (D22); the decline is correct (corpus has nothing on that error).

Pattern in the 10 minor-edits drafts: zero fabricated steps/settings (grounding works), but several
answer the *topic* rather than the exact symptom, and cases whose only error detail is a screenshot
get confident generic triage. Both confirmed FPs share one root: **licensing/billing threads that
lexically resemble how-to questions.**

## What the 31 corpus-gap cases actually need (ranked doc backlog)

Clusters from the C-labeled cases (count = labeled instances; deep-low extrapolates further):

1. **Known-error docs for named product errors (9 cases)** — each of these appeared verbatim in a
   case and has no doc: DOCX upload "invalid field ID"; `SDTemplate__c sObject type not supported`
   (flow-created jobs); `SSTemplateEditor page does not exist` (fresh sandbox install);
   `GenerateDocumentInvocable` null-object (v6.1.10); "Ending position out of bounds";
   `Invalid type: ContentDistribution` (Content Deliveries disabled); zqu_Quote__c missing-object;
   invalid S-Sign license key causes; multi-template job-splitter limitation.
2. **Upgrade/installation paths (3)** — skip-version upgrades (v8→v11), External Client Apps
   migration, DOCX-to-PDF output fidelity.
3. **Capability/how-to gaps (7+)** — JPG-in-PDF rendering support, per-user usage reporting,
   merge-field truncation attribute, next-signer email template, S-Sign signing-view hyperlinks,
   logo positioning, UI-sort persistence in generated tables, HubSpot-edition access.

Writing cluster 1 alone addresses ~9 labeled (+~4 extrapolated) declines AND converts several
current model-declines from "correct decline" to "draftable".

## Case-hygiene finding (inflates the denominator)

The deep-low band is full of non-cases: 3 **auto-reply mail loops** (support's own "Ticket
received" bouncing back as new cases), 2 marketing newsletters, 2 Teams-invite-only bodies, 1
different-vendor call transcript. Extrapolated: **~13 of the 100 evaluated "cases" were junk mail
the pipeline correctly ignored but still paid retrieval callouts for.** A pre-flow guard (skip
auto-reply loops / no-reply senders) cleans both the stats and the spend.

## Ranked recommendations

| # | Action | Evidence | Predicted effect |
|---|---|---|---|
| 1 | **Fix the multi-product filter** (treat `S-Docs;S-Sign` as search-both) | 7/100 hard-zeroed (eval report) | +7 cases can compete; ~+1–2 drafts |
| 2 | **topScore := content-max across candidates** (2-line class change) | A1/A3 = 4 labeled cases; CF-1 = 5 crossings, all floor-gated + model-gated afterward | +2–5 drafts, near-zero FP risk |
| 3 | **Write cluster-1 known-error docs** (9 named errors) | C = 39% of declines, largest single bucket | Largest long-term lift; also upgrades some correct-declines to drafts |
| 4 | **Add licensing/billing exclusion** (the flow's unused `excluded` input; keyword/queue-based) | Both confirmed FPs are billing threads; 8 labeled D-cases are limit/license asks | Removes the main FP class; skips wasted generation |
| 5 | **Pre-flow junk-mail guard** (auto-reply loops, no-reply senders, newsletters) | ~13/100 junk | Cleaner stats, fewer callouts |
| 6 | **Re-measure the semantic band on the current corpus** (rerun the D19 band measurement; consider simFloor ~0.72 only with #4 in place) | CF-2: 17–21 crossings but labels show most are C/D | Recovers part of A2 (~6.5 cases) at controlled FP cost |
| 7 | Leave the model decline gate alone | 15/18 declines correct | — |

**Realistic ceiling with #1+#2 (+#6 measured): roughly 20–25/100 drafted.** The mid-30s%+ range is
reachable only through the corpus backlog (#3) — i.e., after fixing two genuine but modest scoring
defects, **the remaining gap between 14% and the mid-30s is knowledge, not math.** The absolute
ceiling given today's caseload composition is ~55% (everything except D), and only if every doc-able
question gets a doc.

## Caveats

- Distill sampling variance is real: 3 of 38 below-floor cases crossed 0.45 on re-probe; one
  originally-drafted case declined on regen. Strata were attributed by original-eval scores; labels
  judge doc existence, which is stable.
- Deep-low stratum is a 15/38 sample (extrapolation noted above); other strata exhaustive.
- "Answering doc" judgments are strict (doc must contain the actual fix, not the topic); all A/B
  labels were mechanically verified against probe pool/candidate data (9/10 exact; the 10th is the
  documented distill flip).
- Probe artifacts: 30 `Retrieval Probe` / `Draft Regen Probe` ContentVersions remain in the org
  Files — deletable once this report is accepted.

---
*Data: `eval-diagnosis-labels-2026-07-16.csv` (70 per-case labels), probe JSONs (org ContentVersions
+ local scratchpad), `scripts/apex/probe_retrieval.apex` / `probe_draft_regen.apex` /
`fetch_probe.apex` (reusable read-only diagnostics). Companion: `eval-report-2026-07-15.md`.*
