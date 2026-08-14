# Support agent guide — finding & sending the AI draft

When an **email** Case comes in, the AI drafter runs automatically in the background and, when it can
answer confidently, leaves a **ready-to-review reply** on the Case. It never sends anything — you always
review, edit, and send. Here is how to spot it.

## How to identify the AI draft

You have **two** signals on the Case, and they always agree:

1. **A Draft email on the Case Feed.** Open the Case → **Feed** (or the **Emails** related list). The AI
   reply appears as an email in **Draft** status (it shows a *Draft* badge and sits in the email composer,
   not in the sent timeline). Its subject is `Re: <the customer's subject>`, it is already addressed to the
   customer, threaded under their message, and — when the account has a Customer Success Manager — the CSM
   is already on **Cc**. Click it to review, edit, and **Send**.

2. **The `AI_Draft_*` fields on the Case record.** Add them to the page layout / a list view to triage at a
   glance:
   - **`AI_Draft_Status__c`** — `DRAFTED` means a reply is waiting. Anything starting with `NO_DRAFT_` or
     `ESCALATE` means the AI intentionally did **not** write a reply (no confident match, needs escalation,
     excluded category, etc.) and the Case is yours to handle from scratch.
   - **`AI_Draft_Confidence__c`** — `HIGH` / `MEDIUM` / `LOW`. Read a `LOW`/`MEDIUM` draft extra carefully.
   - **`AI_Draft_Body__c`** — the same reply text as the Draft email (handy for a quick read without opening
     the composer).
   - **`AI_Draft_Notes__c`** — structured reviewer notes, one labeled line each. **Read this before sending.**
     - `Explanation:` — the AI's own notes on the answer (assumptions, gaps, escalation hints).
     - `Confidence:` — the final tag **and why** it landed there (model self-report vs retrieval evidence,
       plus any cap or floor applied).
     - `Source used:` — the knowledge doc the reply is built on, as *Title – link (id)*.
     - `Top sources considered:` — the top 3 ranked candidates the AI saw, with retrieval scores.
     - Any extra lines below are status flags: grounding warnings, a model decline reason, an appended
       disclaimer, or the retrieval-query audit.
   - **`AI_Draft_Source_Ids__c`** — the knowledge-store solutions the draft was built from (audit trail).

> **Fast triage:** a list view filtered to `Origin = Email` and `AI_Draft_Status__c = DRAFTED`, sorted by
> `AI_Draft_Confidence__c`, surfaces every case with a reply waiting for review.

## What's already in every drafted reply

So you have less to add before sending, each `DRAFTED` reply already includes:

- **An offer to schedule a call**, with stated availability (a fixed blurb — edit the wording in
  `Support_Draft_Setting__mdt.Default.Draft_Call_Offer_Text__c`, no deploy needed).
- **Links to the relevant documentation** the answer was drawn from.
- **A sign-off with the case owner's email signature** (`Case.Owner.Signature`). If the case is still owned
  by a queue or the owner has no signature on file, it falls back to a generic *"Sincerely, The Support
  Team."* — replace it with your own before sending.
- **The account CSM on Cc** (when `Account.CSM_Email__c` is populated).

Always give the draft a final read — confirm the facts, adjust the tone/availability if needed, make sure
the signature is yours, then send.

## If there's no draft

`NO_DRAFT_*` / `ESCALATE` is normal and safe — it means the AI was not confident enough to answer, so it
stepped aside rather than guess. `AI_Draft_Notes__c` explains why. Handle the Case as you normally would.
If the Draft email is missing on a `DRAFTED` Case, check `AI_Draft_Notes__c` for an *"Enable Email Drafts"*
message (an org setting must be on for the draft email to be created).

`NO_DRAFT_EXCLUDED` means the case was filtered out **before** drafting was even attempted: either junk
mail (auto-replies, bounce notices, "Ticket received:" mail loops, newsletters, calendar invites — the
notes start with *"Junk mail:"*) or a billing/licensing transaction the knowledge base can't answer (notes
start with *"Billing/licensing:"* or *"Excluded category:"*). These are deliberate skips by
`CaseIntakeClassifier`, not failures. If a real product question was wrongly excluded, flag it — the
classifier's rules are precision-tuned from these reports.

## Where the knowledge docs come from

Drafts are grounded in `Support_Solution__c` docs from three sources: the help.sdocs.com sync (space keys
`quick-start` / `sdocs` / `s-sign` / `developer-hub`), the curated common-case seeds (`sdocs-cases`), and
**case-mined docs** (`case-mined`) generated from resolved support cases / researched backlog topics and
auto-ingested behind mechanical quality gates (grounding-only generation, adversarial verification, PII
scrub). Mined docs carry their provenance in `Mined_From_Cases__c`. To pull every mined doc out of
retrieval in one step, run `scripts/apex/rollback_case_mined.apex` (deactivates, never deletes).
