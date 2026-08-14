# Pinned-Cohort Re-run #1 — Phase 1 Fixes Verified (2026-07-16)

Re-ran the exact 100-case cohort of `eval-run-2026-07-15.csv` through the deployed pipeline after the
Phase 1 changes (D30): multi-product filter split, content-max topScore, and the `CaseIntakeClassifier`
junk/billing pre-guards. Dry run via `scripts/apex/run_draft_eval_pinned.apex`; report CV
`Draft Eval eval-pinned-2026-07-16`.

## Headline

| Metric | Baseline (07-15) | Pinned re-run #1 | Note |
|---|---|---|---|
| DRAFTED | 14 | 12 | −2 billing FPs excluded, −2 distill flips, +2 recovered multi-product |
| NO_DRAFT_NO_MATCH | 7 | **0** | multi-product fix: all 7 hard-zeros now retrieve and compete |
| NO_DRAFT_EXCLUDED | 0 | 8 | 3 junk + 5 billing (audited below) |
| Legit denominator (intake=LEGIT) | — | 92 | **legit draft rate 12/92 = 13.0%** |

The two confirmed false positives from the diagnosis audit (00033797 billing thread and one more
renewal thread) are both now `NO_DRAFT_EXCLUDED` — the confirmed-FP class is closed. Probe smoke on
three former NO_MATCH cases: topScores 0.77 / 0.54 / 0.63 (HIGH) with plausible right docs (e.g.
"Upgrade to newest version" → the upgrade-links doc).

## Exclusion audit (all 8 rows hand-checked)

Junk (3): donotreply@moneypenny.com sender, forwarding-noreply@google.com sender, TimeLynx webinar
newsletter — all correct. Billing (5): Admin Access (licensing ask), manual-billing marketing thread,
one "Ticket received:" ack loop misrouted to BILLING (should be JUNK — see below), S-Docs Renewal fwd,
Renewal OVERDUE (the confirmed FP case) — all correctly excluded from drafting; one label wrong.

**Classifier gap found and fixed:** 4 more "[#REF] Ticket received: S-Docs Support Case #: …" ack-loop
cases sat in LEGIT because the ack-loop regex was start-anchored. Rule is now unanchored on
`ticket received:` / `s-docs support case #:` (colon keeps prose like "no ticket received after signing"
legit). Deployed same day; the next run's denominator drops to ~87 legit.

## Distillation noise (expected)

2 baseline DRAFTED cases declined this run (both were distill-dependent, D22's known straddle);
±3–4 case flips per run is the documented variance — aggregates only.

## Where the remaining 80 legit declines sit

35 legit declines score in the 0.25–0.45 band (the Phase 3 band re-measure population; caseIds in the
band-measurement worklist). Recurring topics visible in this cohort that the seed backlog now covers:
JPEG rendering, GenerateDocumentInvocable, sandbox Template Editor error, table sorting, External Client
Apps, upgrade paths, usage reporting — plus a NEW recurring error the diagnosis list missed:
**"SDCreate3 initialization error: Document limit has been reached." (4 cases)**, added to the seed
research list alongside template-cloning and incomplete-jobs.

## Pinned re-run #2 — after the seed-doc corpus expansion (same day)

The corpus-gap lever could not run as designed: **the sandbox has no agent-reply corpus** (69
EmailMessage rows org-wide vs 9,761 Email cases; resolution fields empty; comments are merge
notices), so `CaseMiningJob` (deployed, 27/27 tests) can only harvest in production. Instead, the
seed backlog was **web-researched from public sources** by parallel research agents (help/kb.sdocs
pages, Salesforce docs, community): of 23 topics, **14 could be grounded and were auto-ingested**
(`case-mined:seed:*`, customer_safe/tribal, source URLs in `Mined_From_Cases__c`, help-site link in
`Confluence_URL__c`); **9 were honest NOT_FOUNDs** (DOCX invalid-field-ID, SSTemplateEditor missing,
GenerateDocumentInvocable null, ending-position-out-of-bounds, zqu_Quote__c, invalid S-Sign license
key causes, job-splitter limitation, merge-field truncation, signing-view hyperlinks) — these are
tribal knowledge that needs the production mining run.

| Metric | Baseline 07-15 | Re-run #1 | Re-run #2 |
|---|---|---|---|
| DRAFTED | 14 | 12 | **32** (16 HIGH / 5 MED / 11 LOW) |
| Legit denominator | — | 92 | 88 (ack-loop fix moved 4 to junk) |
| **Legit draft rate** | ~12% | 13.0% | **36.4%** |

+20 new drafts, 0 lost. The seed docs convert exactly their target cases: all four
"Document limit has been reached" cases, JPEG rendering, table sorting, logo positioning, usage
reporting ×2, upgrade paths ×2, sandbox install, incomplete jobs, SDTemplate flow-permission error.

**FP audit (12 of 32 regenerated, incl. every vague-subject HIGH):** 10 sendable as-is/minor edits,
1 regen-declined (D22 straddle), 1 unverifiable without the full thread, **0 wrong-answer drafts**
(bar: ≤2). Drafts quote customers' verbatim errors and cite the correct KB links.

## Band re-measure #2 (post-corpus) — keep simFloor 0.76

26 legit declines sat in the 0.25–0.45 band; all were probed (2 cases/run — CPU ceiling dropped with
the bigger corpus) and re-scored offline under floors {0.76, 0.74, 0.72} with content-max. Floor
0.74 lifts 5 over the draft floor but only ~2 with the right doc; 0.72 lifts 8 with ~4 right. Neither
meets the adopt rule (right ≥ 2× wrong), so the live band stays 0.76/0.86 — widening would mostly
promote generic how-to docs onto questions whose real fix isn't documented yet.

## Fresh-cohort run (eval-fresh-2026-07-16): the generalization check

A fresh random 100-case cohort (17 case overlap with pinned): 94 LEGIT / 4 BILLING / 2 JUNK,
**14/94 = 14.9% legit draft rate**, 0 errors. The seed docs DO generalize — ~6 of the 14 drafts are
seed-doc conversions on never-before-seen cases (three more document-limit threads, logo
positioning, trial-install, usage) — but the pinned cohort's 36.4% overstates the population rate
because the seed topics were chosen from that cohort's own gaps.

**The new binding constraint is corpus breadth, not scoring:** 32 of the fresh declines score ABOVE
the 0.45 floor and were declined by the model, whose explanations are specific and (spot-checked)
correct — each names the missing doc ("does not mention LibreOffice compatibility", "does not
address the Download-Document failure after upgrade", "does not cover dynamic recipient
configuration"). The decline notes are, verbatim, the next doc backlog. Per-cohort gap topics are
long-tail and largely disjoint between cohorts, so closing them by hand-research doesn't scale —
**the production CaseMiningJob run (or a sandbox refresh that includes EmailMessage) is the
unlock.**

Two classifier leaks found in this cohort were fixed and deployed same day (v3, 33/33 tests):
Outlook "Recall:" notices → JUNK; seat-count/quota commerce ("Add additional SDocs licences",
"license count", "quota reset") → BILLING (one such case had drafted at LOW — the FP class the
exclusion exists for).

## Honest scorecard and the path forward

| | Before (07-15) | After (07-16, deployed) |
|---|---|---|
| Pinned cohort legit rate | ~12% | **36.4%** |
| Fresh cohort legit rate | ~13-15% | **14.9%** (~20%+ expected once live, incl. seed generalization + classifier v3) |
| NO_MATCH hard zeros | 7/100 | 0 |
| Confirmed FP drafts | 2/14 | 0/12 audited |

Next iteration loop (repeatable, ~1 day/cycle): (1) run CaseMiningJob against production data —
this needs a human decision; (2) alternatively feed each fresh run's above-floor decline notes to
the web-research seeding pipeline (works for publicly documented topics only); (3) re-embed,
pinned re-run, fresh cohort, FP audit.

## Cycle 2 (2026-07-17): research-seeding from fresh-1's decline notes

The fresh-1 above-floor decline notes seeded 11 research topics; **10 grounded and ingested**
(DOCX table formatting, output-format/LibreOffice compatibility, S-Sign UI translation, latest
release info, conditional RENDER sections, permission-sets overview, dynamic signer recipients,
format-number incl. aggregate aliases, images in HTML templates, wrap-text/breakeverynchars;
barcode = honest NOT_FOUND, the PDF font limits rule it out). Corpus now 24 case-mined docs, all
embedded.

| Cohort | Pre-cycle-2 | Post-cycle-2 |
|---|---|---|
| Pinned (same 100) | 36.4% | **39.1%** (34/87; classifier v3 denominator) |
| Fresh (new random 100) | 14.9% (fresh-1) | **23.9%** (fresh-2, 22/92) |

Fresh-2 confirms generalization: the cycle-2 docs drafted their target topics on unseen cases
(Images-in-HTML, LibreOffice, dynamic recipients, wrap-text), and cycle-1 seeds kept converting
(doc-limit, logo, quota/free-tier, sandbox errors).

**Why autonomous cycles stop here:** fresh-2's 30 remaining above-floor declines are dominated by
case-specific/tribal content (unspecified template errors, stuck envelopes, org email config,
mobile signing edge cases, install-URL requests) — public-web research can't ground these; only
~5 thin public topics remain. The next material lift requires **CaseMiningJob against production
agent replies** (run in production, or refresh this sandbox with EmailMessage included). Trajectory
so far: 13% → 36.4% pinned / 15% → 24% fresh across two corpus cycles, zero wrong-answer drafts in
audits, model gate untouched.
