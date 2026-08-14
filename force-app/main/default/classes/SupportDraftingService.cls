/**
 * Generation: turns a case + retrieved solutions into one reviewable draft (at most one Models call).
 * Gates run before the metered call; NO_DRAFT_* outcomes route to a human. Config: Support_Draft_Setting__mdt.
 */
public with sharing class SupportDraftingService {

    public interface ModelClient {
        String generate(String modelName, String prompt);
    }

    public class EinsteinModelClient implements ModelClient {
        public String generate(String modelName, String prompt) {
            return EinsteinAiClient.chat(modelName, prompt);
        }
    }

    @TestVisible
    private static ModelClient client = new EinsteinModelClient();

    // Test override for the mdt grounding flag (tests can't write mdt).
    @TestVisible
    private static Boolean testForceGrounding;

    // Test overrides for the two precision gates. The mdt Default enables both in production, but CMDT is
    // visible in test context, so these gates default OFF under Test unless a test explicitly opts in.
    @TestVisible
    private static Boolean testForceClaimCheck;
    @TestVisible
    private static Boolean testForceVerify;
    // Pins the verify model under test — the live CMDT value (the org runs the GPT-4o judge) would
    // otherwise make model assertions org-dependent.
    @TestVisible
    private static String testForceVerifyModel;
    // Pins the gate mode under test (the org record runs 'demote'; the test default stays 'block'
    // so the existing fail-closed gate tests keep asserting the block behavior).
    @TestVisible
    private static String testForceGateMode;
    // Opt-ins for the structural pre-decline and the verify second vote (both default OFF under Test).
    @TestVisible
    private static Boolean testForceStructuralDecline;
    @TestVisible
    private static Boolean testForceVerifySecondVote;

    // Trust tiers that are never customer-reply fuel even when Visibility__c is customer_safe.
    private static final Set<String> DRAFT_TRUST_EXCLUDED = SupportDraftVocab.DRAFT_TRUST_EXCLUDED;

    // ---- public data types ----

    public class SolutionContext {
        public String solutionId;
        public String name;
        public String sourceType;
        public String visibility;             // customer_safe / agent_only / escalate_only
        public String solutionType;           // template / procedure / reference / explainer
        public String product;                // S-Docs / S-Sign — surfaced so the model can reject cross-product docs
        public Boolean hasRequiredDisclaimer; // text fetched by Id when true
        public String requiredDisclaimerText; // optional inline text (else fetched)
        public String url;
        public String body;
        public Double relevanceScore;         // retrieval score [0,1]
    }

    public class DraftInput {
        public String caseSubject;
        public String caseDescription;
        public String product;              // S-Docs / S-Sign
        public String customerName;
        public Boolean excluded = false;    // hard exclusion decided upstream (security/PII/legal/refund)
        public String excludedReason;
        public String retrievalConfidence;  // HIGH | MEDIUM | LOW | NONE (from retrieval)
        public Double retrievalTopScore;    // numeric top retrieval score (gating floor; null = unknown)
        public List<SolutionContext> solutions = new List<SolutionContext>();
    }

    public class DraftResult {
        // DRAFTED | NO_DRAFT_EXCLUDED | NO_DRAFT_NO_MATCH | NO_DRAFT_LOW_CONFIDENCE | NO_DRAFT_UNGROUNDED |
        // NO_DRAFT_UNVERIFIED | NO_DRAFT_MODEL_ERROR
        public String status;
        public String draftText;            // null unless status = DRAFTED
        public List<String> sourceIds = new List<String>();
        public String confidence = 'NONE';  // HIGH | MEDIUM | LOW | NONE
        public String notes;                // agent-facing notes (sources used, escalation hints, errors)
        public String modelName;            // which model produced this (audit trail)
        // Gates that flagged a DRAFTED outcome in demote mode, csv of 'grounding'/'claims'/'verify';
        // null when the draft cleared every gate (the clean-vs-flagged eval split reads this).
        public String gateFlags;
    }

    private class Config {
        String modelName = SupportDraftVocab.MODEL_DRAFTING_DEFAULT;
        Integer maxSolutions = 5;
        Integer solutionCharLimit = 1200;       // per-solution cap for reference/explainer
        Integer solutionTotalCharBudget = 8000; // combined-body ceiling (token guard)
        String promptInstructions = DEFAULT_PROMPT;
        Integer maxRetries = 2;                 // re-issue on empty/thrown callout only
        // Below this top retrieval score we never draft (the shared pipeline draft floor).
        Double minTopScore = SupportDraftVocab.DRAFT_FLOOR.doubleValue();
        Boolean groundingEnabled = true;
        Double groundingMinOverlap = 0.5;       // sentence "supported" at/above this token overlap
        Double groundingBlockRatio = 0.34;      // block the draft when supported/evaluated falls below
        // Floor for a drafted, grounded outcome so habitual model caution doesn't read as a weak match.
        String draftedConfFloor = 'MEDIUM';
        String callOfferText = DEFAULT_CALL_OFFER; // appended deterministically; blank = none
        // Precision gates on a would-be draft (both default OFF in code; the mdt Default turns them on).
        Boolean claimCheckEnabled = false;         // deterministic per-claim fabrication check (no model call)
        Integer claimCheckMaxUnverified = 0;       // tolerated unverifiable specifics (0 = zero-tolerance)
        Boolean verifyEnabled = false;             // second, cheap model call that must approve the draft
        String verifyModelName = SupportDraftVocab.MODEL_MINI_DEFAULT;
        // block (default, fail-closed) | demote — see SupportDraftVocab.GATE_MODE_*.
        String gateMode = SupportDraftVocab.GATE_MODE_BLOCK;
        // Deterministic pre-decline for structurally unanswerable cases (screenshot-only / regression).
        Boolean structuralDeclineEnabled = false;
        // Demote mode: a second verify sample on a first-vote decline; both declining blocks.
        Boolean verifySecondVote = false;
    }

    /**
     * One draft for one case. At most one Models call, and only when it is safe to draft.
     * A linear gauntlet of named gates in a FIXED order (each gate's method doc says why it exists):
     * every gate either stamps a terminal NO_DRAFT_* outcome on the shared DraftResult and returns
     * it, or returns null to let the run proceed to the next gate.
     */
    public static DraftResult draft(DraftInput input) {
        DraftRun run = new DraftRun();
        run.input = input;
        DraftResult gated;

        gated = gateInput(run);             if (gated != null) { return gated; }
        gated = gateNoSafeMatch(run);       if (gated != null) { return gated; }

        run.cfg = loadConfig();
        run.out.modelName = run.cfg.modelName;

        gated = gateScoreFloor(run);        if (gated != null) { return gated; }
        gated = gateStructural(run);        if (gated != null) { return gated; }
        selectFedSolutions(run);
        gated = generateWithRetry(run);     if (gated != null) { return gated; }
        parseReply(run);
        gated = gateDecline(run);           if (gated != null) { return gated; }
        gated = gateGrounding(run);         if (gated != null) { return gated; }
        gated = gateClaims(run);            if (gated != null) { return gated; }
        gated = gateVerify(run);            if (gated != null) { return gated; }

        return finalizeDrafted(run);
    }

    /** The one draft() run's shared state, threaded through the gates above. */
    private class DraftRun {
        DraftInput input;
        Config cfg;
        DraftResult out = new DraftResult();
        List<SolutionContext> safeSols;   // customer_safe, reviewed-trust survivors of gateNoSafeMatch
        List<SolutionContext> fed;        // what actually goes into the prompt (count + char budget)
        String raw;                       // the model's raw generation reply
        Map<String, Object> parsed;
        String draftText;
        String agentNotes;
        String sourcesUsed;
        GroundingResult grounding;
        Integer urlsRemoved = 0;
        List<String> gateFlags = new List<String>();    // machine tokens: claims / verify
        List<String> gateWarnings = new List<String>(); // reviewer-facing [NEEDS REVIEW ...] lines
        Boolean claimsHit = false;                      // deterministic claim check failed, awaiting the verify judge
    }

    /** In demote mode a failed verification gate records its flag + warning and lets the run
     *  continue (returns true); in block mode it returns false and the gate's terminal stamp runs. */
    private static Boolean demote(DraftRun run, String flag, String warning) {
        if (SupportDraftVocab.GATE_MODE_DEMOTE.equalsIgnoreCase(run.cfg.gateMode)) {
            run.gateFlags.add(flag);
            run.gateWarnings.add(warning);
            return true;
        }
        return false;
    }

    /** Terminal on null input or an upstream exclusion (junk/billing) — defense in depth with the
     *  orchestrator's identical stamp. */
    private static DraftResult gateInput(DraftRun run) {
        DraftResult out = run.out;
        if (run.input == null) {
            out.status = SupportDraftVocab.NO_DRAFT_NO_MATCH;
            out.notes = 'No input provided.';
            return out;
        }
        if (run.input.excluded == true) {
            out.status = SupportDraftVocab.NO_DRAFT_EXCLUDED;
            out.confidence = 'NONE';
            out.notes = 'Excluded category: ' + (String.isBlank(run.input.excludedReason)
                ? 'flagged do-not-auto-draft' : run.input.excludedReason) + '. Routed to a human.';
            return out;
        }
        return null;
    }

    /** Safety gate: only customer_safe, reviewed-trust solutions are draft fuel — a deterministic
     *  backstop even if the Flow routing is misconfigured. Terminal when nothing safe remains or
     *  retrieval reported no evidence at all. */
    private static DraftResult gateNoSafeMatch(DraftRun run) {
        List<SolutionContext> sols = (run.input.solutions == null)
            ? new List<SolutionContext>() : run.input.solutions;
        run.safeSols = new List<SolutionContext>();
        for (SolutionContext s : sols) {
            if (s != null && SupportDraftVocab.VIS_CUSTOMER_SAFE.equalsIgnoreCase(s.visibility)
                    && !DRAFT_TRUST_EXCLUDED.contains(s.sourceType == null ? '' : s.sourceType.toLowerCase())) {
                run.safeSols.add(s);
            }
        }
        Boolean retrievalEmpty = run.safeSols.isEmpty()
            || 'NONE'.equalsIgnoreCase(run.input.retrievalConfidence);
        if (retrievalEmpty) {
            run.out.status = SupportDraftVocab.NO_DRAFT_NO_MATCH;
            run.out.confidence = 'NONE';
            run.out.notes = sols.isEmpty()
                ? 'No matching knowledge-store solution; routed to a human.'
                : 'No customer-safe, reviewed solution among the matches (internal / escalate-only / '
                    + 'unreviewed-draft); routed to a human.';
            return run.out;
        }
        return null;
    }

    /** Score floor, decided BEFORE the metered call: the model's self-assessment is never the only gate. */
    private static DraftResult gateScoreFloor(DraftRun run) {
        Double topScore = run.input.retrievalTopScore;
        if (topScore != null && topScore < run.cfg.minTopScore) {
            run.out.status = SupportDraftVocab.NO_DRAFT_LOW_CONFIDENCE;
            run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
            run.out.notes = 'Top retrieved solution scored ' + round2(topScore) + ' (< drafting floor '
                + round2(run.cfg.minTopScore) + '); not drafted regardless of model confidence. Routed to a human.';
            return run.out;
        }
        return null;
    }

    // ---- structural-unanswerability pre-decline (deterministic, before the metered call) ----

    // The case references an image/attachment the pipeline cannot read — PROSE references only.
    // [cid:...] / [image...] markers are deliberately excluded: Outlook signature logos embed
    // cid images in virtually every corporate email (measured FP: 00034164, a purely textual
    // release question structurally declined because of its sender's signature logo).
    @TestVisible private static final Pattern STRUCT_IMAGE_REF = Pattern.compile(
        '(?i)(screen ?shot|see (the |my )?attach(ed|ment)'
        + '|please find (the )?attach(ed|ment)|attached (is |are |a |an |the )?(image|file|photo|error)'
        + '|in the attach(ed|ment)|see (the )?images? (below|above)|images? (below|attached))');
    // A previously-working setup broke: org investigation territory, not a KB answer.
    @TestVisible private static final Pattern STRUCT_REGRESSION = Pattern.compile(
        '(?i)(worked (fine |well |ok |okay |perfectly |correctly )?(yesterday|last (week|month)|until|before|previously)'
        + '|(suddenly|randomly|just) stopped|stopped (working|generating|sending)'
        + '|no longer (works|working|generates|sends)|was working|(has|have) been working|out of nowhere)');
    // A regression that names a platform release maps to the release-compatibility corpus topics —
    // spare it so an authored release doc can draft it.
    @TestVisible private static final Pattern STRUCT_RELEASE_MENTION = Pattern.compile(
        '(?i)((spring|summer|winter)\\s*[\'\\u2019]?\\s*\\d{2}|release|patch|upgraded? to|new version|latest version)');
    // A quoted error string long enough to be searchable evidence. Double/smart quotes only — a
    // single-quote branch reads every apostrophe as a potential open quote, and on long
    // apostrophe-dense case text that blew the regex engine ('Regex too complicated', fresh250
    // chains 2026-07-23).
    private static final Pattern STRUCT_QUOTED_ERROR = Pattern.compile(
        '"[^"\\n]{12,}"|\\u201c[^\\u201d\\n]{12,}\\u201d');
    // The structural detectors read only the ask region: the customer states their problem up
    // front, quoted threads/signatures below add regex surface (the engine's work cap is the
    // hard constraint on raw case text) and signature-noise FPs.
    @TestVisible private static final Integer STRUCT_SCAN_CHARS = 3000;
    // An explicit error sentence: "error: ...", "error message says ...", "exception code = ...".
    private static final Pattern STRUCT_ERROR_SENTENCE = Pattern.compile(
        '(?i)(error|exception)\\s*(message|code|text)?\\s*(says|reads|is|was|[:=])');
    // A version number or a Salesforce org id — concrete, matchable specifics. Major version is
    // capped at 2 digits so dotted phone numbers ("231.346.8780" — smoke case 00034112) do not
    // read as substance.
    private static final Pattern STRUCT_VERSION_OR_ORG = Pattern.compile(
        '(?i)\\bv\\d+(?:\\.\\d+)+\\b|\\b\\d{1,2}\\.\\d{1,3}(?:\\.\\d{1,3})?\\b|\\b00D[a-z0-9]{12,15}\\b');
    // An articulated how/why/is-there question: the customer states the substance in prose, so the
    // case is answerable even if a screenshot is also mentioned.
    private static final Pattern STRUCT_QUESTION = Pattern.compile(
        '(?i)(let (me|us) know (how|why|what)|how (do|can|to|does|would)\\b|why (is|does|did|would)\\b'
        + '|is there a (way|workaround)|would like (your|some) (guidance|support|help)'
        + '|require[sd]? (your )?guidance|can you (advise|explain|confirm))');

    /** The case text itself carries enough substance to retrieve and draft from — identifiers,
     *  merge/attr syntax, a quoted or spelled-out error, a version/org id, or an articulated
     *  question — so the structural detectors stand down. 2026-07-23 pinned smoke evidence: the
     *  first, code-token-only version of this veto killed 4 good drafts (00033705 org id,
     *  00033957 version 4.439, 00033976 "how/why this happened", 00034122 "require your
     *  guidance") because a screenshot MENTION does not make a case screenshot-ONLY. All four are
     *  covered by the version/org-id/question signals; bare CamelCase is deliberately NOT a
     *  signal — brand words (HubSpot, DocuSign) would spare exactly the thin screenshot cases
     *  this gate exists to decline. */
    @TestVisible
    private static Boolean hasConcreteErrorSignal(String text) {
        if (String.isBlank(text)) { return false; }
        for (Pattern p : new List<Pattern>{
                CLAIM_API_NAME, CLAIM_MERGE, CLAIM_ATTR,
                STRUCT_QUOTED_ERROR, STRUCT_ERROR_SENTENCE, STRUCT_VERSION_OR_ORG, STRUCT_QUESTION }) {
            if (p.matcher(text).find()) { return true; }
        }
        return false;
    }

    /** Structural-unanswerability pre-decline, decided BEFORE the metered call. The dominant
     *  bad-draft family on unseen cohorts (2026-07-23: 10 of 20 not_sendable) is cases whose
     *  decisive evidence the pipeline cannot see — screenshot-only errors and "worked yesterday"
     *  regressions. A draft there answers the general topic, not the customer's actual problem, so
     *  a high retrieval score must not draft it. Both detectors stand down when the case text
     *  carries concrete error evidence; the regression detector also stands down on a platform-
     *  release mention (release-compat docs are an authored corpus topic). */
    private static DraftResult gateStructural(DraftRun run) {
        if (!run.cfg.structuralDeclineEnabled) { return null; }
        String text = nz(run.input.caseSubject) + '\n' + nz(run.input.caseDescription);
        if (text.length() > STRUCT_SCAN_CHARS) { text = text.substring(0, STRUCT_SCAN_CHARS); }
        if (hasConcreteErrorSignal(text)) { return null; }

        String kind = null;
        String why = null;
        if (STRUCT_IMAGE_REF.matcher(text).find()) {
            kind = 'screenshot_only';
            why = 'the decisive error appears to live in a screenshot/attachment the pipeline cannot read';
        } else if (STRUCT_REGRESSION.matcher(text).find()
                && !STRUCT_RELEASE_MENTION.matcher(text).find()) {
            kind = 'regression';
            why = 'a previously-working setup broke with no error text; needs org investigation, not a KB answer';
        }
        if (kind == null) { return null; }

        run.out.status = SupportDraftVocab.NO_DRAFT_LOW_CONFIDENCE;
        run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
        run.out.notes = 'Structurally unanswerable from the knowledge store: ' + why
            + '. Not drafted regardless of retrieval score. Routed to a human.'
            + '\n[structural: ' + kind + ']';
        return run.out;
    }

    /** Feed what retrieval's adaptive selection chose, bounded by count + total char budget. */
    private static void selectFedSolutions(DraftRun run) {
        run.fed = new List<SolutionContext>();
        Integer budget = 0;
        for (Integer i = 0; i < run.safeSols.size() && i < run.cfg.maxSolutions; i++) {
            Integer cost = (run.safeSols[i].body == null) ? 0 : run.safeSols[i].body.length();
            if (!run.fed.isEmpty() && budget + cost > run.cfg.solutionTotalCharBudget) { break; } // token guard
            run.fed.add(run.safeSols[i]);
            run.out.sourceIds.add(run.safeSols[i].solutionId);
            budget += cost;
        }
    }

    /** The one metered generation call. Retry only transient-shaped failures (empty/thrown); a
     *  non-blank response is final. Terminal NO_DRAFT_MODEL_ERROR on exhaustion. */
    private static DraftResult generateWithRetry(DraftRun run) {
        String prompt = buildPrompt(run.input, run.fed, run.cfg);
        String raw = null;
        Exception lastEx = null;
        Integer attempts = 0;
        Integer maxAttempts = 1 + Math.max(0, run.cfg.maxRetries);
        while (attempts < maxAttempts) {
            attempts++;
            try {
                raw = client.generate(run.cfg.modelName, prompt);
            } catch (Exception e) {
                lastEx = e;
                raw = null;
            }
            if (String.isNotBlank(raw)) { break; } // got a usable response -> stop retrying
        }
        if (String.isBlank(raw)) {
            run.out.status = SupportDraftVocab.NO_DRAFT_MODEL_ERROR;
            run.out.confidence = 'LOW';
            run.out.notes = (lastEx != null)
                ? 'Generation callout failed after ' + attempts + ' attempt(s): ' + lastEx.getMessage()
                    + '. Routed to a human.'
                : 'Model returned an empty response after ' + attempts + ' attempt(s). Routed to a human.';
            return run.out;
        }
        run.raw = raw;
        return null;
    }

    private static void parseReply(DraftRun run) {
        run.parsed = parseJson(run.raw);
        run.draftText = stringValue(run.parsed, 'draft');
        run.agentNotes = stringValue(run.parsed, 'agent_notes');
        run.sourcesUsed = stringValue(run.parsed, 'sources_used');
    }

    /** The model's own decline paths: can_answer=false is a deliberate decline — honoured even if a
     *  draft string came back — then an empty draft is split into a deliberate decline (parsed, with
     *  an explanation) vs a garbled/failed generation. */
    private static DraftResult gateDecline(DraftRun run) {
        DraftResult out = run.out;
        if (!run.parsed.isEmpty() && boolValue(run.parsed, 'can_answer', true) == false) {
            out.status = SupportDraftVocab.NO_DRAFT_LOW_CONFIDENCE;
            String declineConf = clampConfidence(
                normalizeConfidence(stringValue(run.parsed, 'confidence')), run.input.retrievalConfidence);
            out.confidence = clampConfidence(declineConf, 'LOW');
            String missing = stringValue(run.parsed, 'missing');
            out.notes = buildNotes(run.agentNotes, run.sourcesUsed, out.confidence,
                    'the model declined to draft; a decline is capped at LOW (retrieval evidence '
                    + nz(run.input.retrievalConfidence) + ')', run.fed)
                + '\n[model: cannot answer from retrieved docs'
                + (String.isBlank(missing) ? '' : ': ' + missing.trim()) + ']';
            return out;
        }
        if (String.isBlank(run.draftText)) {
            // The model may decline via an empty draft + agent_notes without setting can_answer.
            if (!run.parsed.isEmpty() && String.isNotBlank(run.agentNotes)) {
                out.status = SupportDraftVocab.NO_DRAFT_LOW_CONFIDENCE;
                String declineConf = clampConfidence(
                    normalizeConfidence(stringValue(run.parsed, 'confidence')), run.input.retrievalConfidence);
                out.confidence = clampConfidence(declineConf, 'LOW');
                out.notes = buildNotes(run.agentNotes, run.sourcesUsed, out.confidence,
                        'the model declined to draft; a decline is capped at LOW (retrieval evidence '
                        + nz(run.input.retrievalConfidence) + ')', run.fed)
                    + '\n[model declined: solutions did not fully answer the case]';
                return out;
            }
            out.status = SupportDraftVocab.NO_DRAFT_MODEL_ERROR;
            out.confidence = 'LOW';
            out.notes = 'Model returned an empty or unparseable draft. Routed to a human.';
            return out;
        }
        return null;
    }

    /**
     * Fabricated-link guard, then the deterministic grounding check. URLs the model invented are
     * stripped rather than blocking the whole draft (a single hallucinated link otherwise sank an
     * otherwise-correct answer; the real doc links are appended deterministically by the footer),
     * but a hallucinated link is still a faithfulness defect, so it flags the draft for review.
     * Grounding runs before the footer/disclaimer appends so only what the MODEL wrote is graded.
     */
    private static DraftResult gateGrounding(DraftRun run) {
        UrlScrubResult us = scrubUngroundedUrls(run.draftText, run.fed);
        run.draftText = us.text;
        run.urlsRemoved = us.removed;

        GroundingResult g = checkGrounding(run.draftText, run.fed, run.cfg);
        if (us.removed > 0) { g.flagged = true; }
        run.grounding = g;
        if (g.blocked) {
            // A grounding hard-fail means the draft is largely NOT built from the cited sources —
            // fabrication territory. Never demotable, regardless of Draft_Gate_Mode__c.
            run.out.status = SupportDraftVocab.NO_DRAFT_UNGROUNDED;
            run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
            run.out.notes = buildNotes(run.agentNotes, run.sourcesUsed, run.out.confidence,
                    'the draft failed the grounding check and was blocked; capped at LOW', run.fed)
                + '\n[grounding BLOCKED: ' + nz(g.summary) + ']';
            return run.out;
        }
        return null;
    }

    /** Claim-level fabrication check (deterministic, no model call): every concrete, verifiable
     *  specific the draft asserts (API names, CamelCase identifiers, code/merge syntax, versions)
     *  must appear in a cited source or the customer's own words. Catches fabrications that reuse
     *  source vocabulary and so slip past the aggregate-overlap grounding check. Runs BEFORE the
     *  metered verify gate so it costs nothing. */
    private static DraftResult gateClaims(DraftRun run) {
        ClaimResult cc = checkClaims(run.draftText, run.fed, run.input, run.cfg);
        if (!cc.ok) {
            // The token extractor has known false positives (HTML/CSS normalization artifacts), so a
            // hit is demotable ONLY when the LLM verify judge runs next to adjudicate it. Without a
            // judge, deterministic fabrication evidence fails closed even in demote mode.
            if (run.cfg.verifyEnabled
                    && demote(run, 'claims', '[NEEDS REVIEW - claim check: draft asserts specifics not '
                        + 'found in any cited source: ' + String.join(cc.unverified, ', ') + ']')) {
                run.claimsHit = true;
                return null;
            }
            run.out.status = SupportDraftVocab.NO_DRAFT_UNGROUNDED;
            run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
            run.out.notes = buildNotes(run.agentNotes, run.sourcesUsed, run.out.confidence,
                    'the draft asserted specifics not found in any cited source and was blocked', run.fed)
                + '\n[claim check: unverifiable specifics: ' + String.join(cc.unverified, ', ') + ']';
            return run.out;
        }
        return null;
    }

    /** LLM verification gate: one cheap second-model call that must confirm the draft answers the
     *  customer's SPECIFIC question using ONLY supported claims. Fail closed — any no / uncertainty /
     *  parse error / callout failure declines. Precision over recall: a declined draft costs a
     *  little, a wrong or fabricated answer sent to a customer costs trust. */
    private static DraftResult gateVerify(DraftRun run) {
        VerifyResult vr = verifyDraft(run.draftText, run.input, run.fed, run.cfg);
        if (vr.approved && !(vr.claimsJudged && vr.fabricated)) { return null; }
        if (vr.approved) {
            // Inconsistent judge (approve + fabricated): keep the draft but carry the warning.
            demote(run, 'verify', '[NEEDS REVIEW - judge suspects INVENTED specifics; verify every '
                + 'concrete fact' + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim()) + ']');
            return null;
        }

        // Corroborated fabrication is never demotable: block only when BOTH independent detectors
        // agree — the deterministic claim check found an untraceable concrete token AND the LLM
        // judge confirmed fabrication (or the judge was unreachable, leaving the deterministic
        // evidence unadjudicated). A single sampled judge opinion is too noisy to block on alone
        // (measured: it flags reviewer-approved drafts), so judge-only suspicion demotes below
        // with a loud warning instead. Specificity declines remain ordinary demotes.
        Boolean fabricated = run.claimsHit && (!vr.claimsJudged || vr.fabricated);
        if (fabricated) {
            run.out.status = SupportDraftVocab.NO_DRAFT_UNGROUNDED;
            run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
            run.out.notes = buildNotes(run.agentNotes, run.sourcesUsed, run.out.confidence,
                    'the verification judge found concrete specifics invented beyond the cited '
                    + 'sources; fabricated facts are never shipped', run.fed)
                + '\n[verification gate: fabricated specifics'
                + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim()) + ']'
                + (run.gateWarnings.isEmpty() ? '' : '\n' + String.join(run.gateWarnings, '\n'));
            return run.out;
        }

        // Second independent sample (flag-gated, demote mode only): a single sampled judge's
        // declines run wrong roughly a third to half of the time on fresh topics (2026-07-23 unseen
        // cohorts), so one decline is reviewer-triage signal — but two independent affirmative
        // declines are strong evidence, and that draft blocks instead of burdening the queue.
        // Blocking needs two PARSED declines: an unreachable/garbled second sample falls through
        // to the ordinary demote. Fabrication corroboration above is unaffected.
        if (run.cfg.verifySecondVote
                && SupportDraftVocab.GATE_MODE_DEMOTE.equalsIgnoreCase(run.cfg.gateMode)) {
            VerifyResult vr2 = verifyDraft(run.draftText, run.input, run.fed, run.cfg);
            if (vr2.parsed && !vr2.approved) {
                run.out.status = SupportDraftVocab.NO_DRAFT_UNVERIFIED;
                run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
                run.out.notes = buildNotes(run.agentNotes, run.sourcesUsed, run.out.confidence,
                        'two independent verification samples both declined the draft; declined for safety',
                        run.fed)
                    + '\n[verification gate DECLINED by both votes'
                    + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim())
                    + (String.isBlank(vr2.reason) ? '' : ' | ' + vr2.reason.trim()) + ']';
                return run.out;
            }
        }

        String warning = (vr.claimsJudged && vr.fabricated)
            ? '[NEEDS REVIEW - judge suspects INVENTED specifics; verify every concrete fact'
                + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim()) + ']'
            : '[NEEDS REVIEW - verification declined'
                + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim()) + ']';
        if (demote(run, 'verify', warning)) {
            return null;
        }
        run.out.status = SupportDraftVocab.NO_DRAFT_UNVERIFIED;
        run.out.confidence = clampConfidence('LOW', run.input.retrievalConfidence);
        run.out.notes = buildNotes(run.agentNotes, run.sourcesUsed, run.out.confidence,
                'a second-model verification gate did not approve the draft; declined for safety', run.fed)
            + '\n[verification gate DECLINED'
            + (String.isBlank(vr.reason) ? '' : ': ' + vr.reason.trim()) + ']';
        return run.out;
    }

    /** All gates cleared: resolve the drafted confidence, append the deterministic footer +
     *  disclaimers (after generation so the model can never drop mandatory language or hallucinate
     *  a URL — owner sign-off is applied by the publisher, in HTML), and build the reviewer note. */
    private static DraftResult finalizeDrafted(DraftRun run) {
        DraftResult out = run.out;
        out.status = SupportDraftVocab.STATUS_DRAFTED;
        Integer personaRewrites = scrubVendorReferrals(run);
        String modelConfidence = normalizeConfidence(stringValue(run.parsed, 'confidence'));
        String confidenceWhy = resolveDraftedConfidence(run, modelConfidence);

        String withFooter = appendReplyFooter(run.draftText, run.fed, run.sourcesUsed, run.cfg);
        String withDisclaimer = appendDisclaimers(withFooter, run.fed);
        Boolean disclaimerAdded = (withDisclaimer != withFooter);
        out.draftText = withDisclaimer;

        out.notes = buildNotes(run.agentNotes, run.sourcesUsed, out.confidence, confidenceWhy, run.fed);
        // The GROUNDING FAILED demote warning supersedes the weaker [grounding WEAK] line.
        if (run.grounding.flagged && String.isNotBlank(run.grounding.summary)
                && !run.gateFlags.contains('grounding')) {
            out.notes += '\n[grounding WEAK: ' + run.grounding.summary + ']';
        }
        if (run.urlsRemoved > 0) {
            out.notes += '\n[' + run.urlsRemoved + ' ungrounded URL(s) removed from the draft]';
        }
        if (personaRewrites > 0) {
            out.notes += '\n[' + personaRewrites
                + ' "contact S-Docs" referral(s) rewritten - we ARE S-Docs Support]';
        }
        if (disclaimerAdded) { out.notes += '\n[required disclaimer appended]'; }
        // Demoted draft: the warning block tops the notes so it is the first thing the reviewer
        // (and the eval's 300-char notes excerpt) sees.
        if (!run.gateWarnings.isEmpty()) {
            out.notes = '*** NEEDS REVIEW - ' + run.gateWarnings.size()
                + ' verification gate(s) flagged this draft ***\n'
                + String.join(run.gateWarnings, '\n') + '\n' + out.notes;
        }
        out.gateFlags = run.gateFlags.isEmpty() ? null : String.join(run.gateFlags, ',');
        return out;
    }

    /** The drafted-outcome confidence ladder: clamp the model's confidence to the retrieval
     *  evidence, then either cap at LOW (grounding flagged weak spots) or raise to the drafted
     *  floor (habitual model caution must not read as a weak match). Sets run.out.confidence and
     *  returns the audit "why" line. */
    private static String resolveDraftedConfidence(DraftRun run, String modelConfidence) {
        String clamped = clampConfidence(modelConfidence, run.input.retrievalConfidence);
        run.out.confidence = clamped;
        String confidenceWhy = 'model reported ' + modelConfidence + ', retrieval evidence '
            + nz(run.input.retrievalConfidence) + '; the final tag takes the lower';
        if (!run.gateFlags.isEmpty()) {
            run.out.confidence = clampConfidence(run.out.confidence, 'LOW');
            confidenceWhy += ', then capped at LOW because verification gate(s) flagged this draft ('
                + String.join(run.gateFlags, ',') + ')';
        } else if (run.grounding.flagged) {
            run.out.confidence = clampConfidence(run.out.confidence, 'LOW');
            confidenceWhy += ', then capped at LOW because grounding flagged weak spots';
        } else {
            run.out.confidence = raiseTo(run.out.confidence, run.cfg.draftedConfFloor);
            if (run.out.confidence != clamped) {
                confidenceWhy += ', then raised to the drafted-outcome floor (' + run.cfg.draftedConfFloor
                    + ') because the draft cleared the score floor and grounding';
            }
        }
        return confidenceWhy;
    }

    @TestVisible
    private static String buildPrompt(DraftInput input, List<SolutionContext> fed, Config cfg) {
        String caseBlock =
            'CASE SUBJECT: ' + nz(input.caseSubject) + '\n' +
            'PRODUCT: ' + nz(input.product) + '\n' +
            'CUSTOMER: ' + nz(input.customerName) + '\n' +
            'RETRIEVAL CONFIDENCE: ' + nz(input.retrievalConfidence) + '\n' +
            'CASE DESCRIPTION:\n' + nz(input.caseDescription) + '\n';

        String solBlock = '';
        Integer n = 1;
        Integer total = fed.size();
        for (SolutionContext s : fed) {
            // template/procedure are pre-approved wording: fed verbatim, never truncated.
            Boolean verbatim = 'template'.equalsIgnoreCase(s.solutionType)
                || 'procedure'.equalsIgnoreCase(s.solutionType);
            String content = verbatim ? nz(s.body) : truncate(nz(s.body), cfg.solutionCharLimit);
            String usage = verbatim
                ? 'reproduce faithfully, fill placeholders, do not paraphrase or shorten'
                : 'synthesize a concise answer from this';
            String rel = (s.relevanceScore == null) ? 'n/a'
                : Decimal.valueOf(s.relevanceScore).setScale(4, System.RoundingMode.HALF_UP)
                    + ' (rank ' + n + ' of ' + total + ')';
            solBlock +=
                '--- SOLUTION ' + n + ' ---\n' +
                'id: ' + nz(s.solutionId) + '\n' +
                'title: ' + nz(s.name) + '\n' +
                'relevance: ' + rel + '\n' +
                'source_type: ' + nz(s.sourceType) + ' (trust: ' + trustLabel(s.sourceType) + ')\n' +
                'solution_type: ' + nz(s.solutionType) + ' (usage: ' + usage + ')\n' +
                'product: ' + nz(s.product) + '\n' +
                'url: ' + nz(s.url) + '\n' +
                'content: ' + content + '\n\n';
            n++;
        }

        return cfg.promptInstructions + '\n\n'
            + '=== CASE ===\n' + caseBlock + '\n'
            + '=== KNOWLEDGE-STORE SOLUTIONS (ranked by retrieval relevance) ===\n' + solBlock
            + '=== OUTPUT ===\n'
            + 'Return ONLY a strict JSON object with exactly these fields:\n'
            + '{"can_answer": true or false  (false if the solutions above do not actually answer THIS '
            + 'case - say so honestly rather than forcing a draft), '
            + '"missing": "if can_answer is false, what specifically is missing or unanswered; else empty", '
            + '"draft": "the reply text to the customer (empty if can_answer is false)", '
            + '"sources_used": "comma-separated ids of the solutions you actually used, or empty", '
            + '"agent_notes": "short notes for the human reviewer: assumptions, gaps, escalation", '
            + '"confidence": "HIGH | MEDIUM | LOW"}';
    }

    // ---- persona: we ARE S-Docs Support ----

    // "contact S-Docs (Support)" referral phrasing leaks into drafts from docs written for end
    // users; in a reply FROM S-Docs Support it reads as deflection (the measured "persona slip"
    // cluster, document-limit template family). Verb list is base-form only so the substitute
    // ("let us know") stays grammatical; -ing forms are left for the reviewer.
    @TestVisible private static final Pattern PERSONA_REFERRAL = Pattern.compile(
        '(?i)(please\\s+)?(contact|reach out to|get in touch with|check with)\\s+(the\\s+)?s-?docs'
        + '(\\s+(customer\\s+)?(support|team|support team))?(\\s+directly)?');

    /** Deterministic rewrite of vendor-referral phrasing in a drafted reply; returns the count. */
    @TestVisible
    private static Integer scrubVendorReferrals(DraftRun run) {
        if (String.isBlank(run.draftText)) { return 0; }
        Matcher m = PERSONA_REFERRAL.matcher(run.draftText);
        Integer count = 0;
        while (m.find()) { count++; }
        if (count > 0) {
            run.draftText = PERSONA_REFERRAL.matcher(run.draftText)
                .replaceAll('let us know').replaceAll('[ \\t]{2,}', ' ');
        }
        return count;
    }

    // Deliberately states no hours/availability — the owner's real free/busy is not in Salesforce.
    @TestVisible
    private static final String DEFAULT_CALL_OFFER =
        'Happy to hop on a call if that\'s easier - just let me know a couple of times that suit you '
        + 'and I\'ll get something on the calendar.';

    // Default drafting instructions; overridden by Support_Draft_Setting__mdt.Draft_Prompt_Instructions__c.
    @TestVisible
    private static final String DEFAULT_PROMPT =
        'You are a support engineer drafting a reply for a HUMAN agent to review before sending. '
        + 'You never send the email yourself.\n'
        + 'RULES:\n'
        + '1. Use ONLY the knowledge-store solutions and the case data below. Do NOT invent product '
        + 'behavior, URLs, prices, commitments, or customer-specific facts that are not present. '
        + 'If the solutions answer only PART of the question, answer that part and explicitly say the '
        + 'documentation does not specify the rest - NEVER fill the gap with a plausible guess (a limit, '
        + 'a reset period, a default, a syntax variant, or how a feature "usually" works). Saying "the '
        + 'docs do not specify X" is always a better draft than an invented X.\n'
        + '2. Trust the solutions by source_type: official/canned (highest) > tribal/tips > unsorted '
        + '(lowest). When solutions '
        + 'conflict, prefer the higher-trust one and note the conflict in agent_notes. Each solution also '
        + 'carries a retrieval relevance score and rank: lean on the higher-relevance solutions; a '
        + 'low-relevance solution is weak evidence even if its trust is high.\n'
        + '3. If the solutions do not actually answer this case, set can_answer=false, leave draft empty, '
        + 'and put what is missing in the missing field - do NOT force a draft from solutions that do not '
        + 'fit. Only set can_answer=true and write a draft when the solutions genuinely address the case.\n'
        + '4. Decline (can_answer=false) or escalate only when you GENUINELY cannot answer from the '
        + 'solutions, or the case needs account-specific data, real-time state, or a risky/irreversible '
        + 'action you cannot verify. Providing standard configuration or setup steps that ARE in the '
        + 'solutions is normal drafting - not a reason to decline or to lower confidence. If the '
        + 'solutions contain the fix for the exact error or feature the customer names, write the '
        + 'draft - do not decline merely because the case mentions context you cannot see (a '
        + 'screenshot, an attachment, an org-specific detail); state the assumption in agent_notes '
        + 'instead.\n'
        + '5. FORMAT & TONE: write the draft as a traditional, professionally formatted support email, '
        + 'never a single wall of text. Use real line breaks (escape each as \\n inside the JSON string; '
        + 'a blank line between paragraphs is \\n\\n). Follow this skeleton exactly:\n'
        + '   a. Greeting on its own line: "Hi <customer first name>," using the real first name from the '
        + 'CUSTOMER field, or "Hi there," if no real name is given. Never guess or invent a name.\n'
        + '   b. Blank line, then ONE brief, warm opening sentence acknowledging the customer\'s question.\n'
        + '   c. The answer body in short paragraphs with a blank line between each. Numbered steps go one '
        + 'per line, with a blank line before and after the list. If the answer covers two distinct topics '
        + '(e.g. manual steps vs. automatic setup), introduce each with its own short intro line followed '
        + 'by its own list or paragraph.\n'
        + '   d. A friendly closing sentence inviting follow-up questions.\n'
        + '   e. STOP after the closing sentence. Do NOT write a sign-off, closing, signature, availability, '
        + 'a call offer, or documentation links yourself: a sign-off with the case owner\'s signature, an '
        + 'offer to schedule a call with available times, and links to any relevant documentation are '
        + 'appended automatically after your draft (exactly like the disclaimer in rule 8). Writing your own '
        + 'would duplicate them.\n'
        + 'Tone is warm, helpful, and human - not robotic. Avoid stiff openers like "Thank you for '
        + 'reaching out"; prefer something like "Thanks for getting in touch - happy to help with this!". '
        + 'Use natural, conversational phrasing while staying professional; vary sentence structure so '
        + 'consecutive sentences do not all start the same way. No corporate filler ("Please be advised", '
        + '"As per your request", "Do not hesitate to contact us"). Use bold or other emphasis only where '
        + 'it genuinely aids scanning.\n'
        + '6. Do NOT include internal source_type labels or internal ids in the customer-facing draft.\n'
        + '7. Solutions with solution_type=template or procedure are pre-approved wording: reproduce '
        + 'them faithfully and fill in placeholders; do not paraphrase or shorten them, though you may '
        + 're-flow line breaks so they sit cleanly inside the rule-5 email skeleton. solution_type='
        + 'reference or explainer are background to synthesize from.\n'
        + '8. Do NOT write legal or compliance disclaimers yourself; any required disclaimer is appended '
        + 'automatically after your draft.\n'
        + '9. CONFIDENCE reflects how well the solutions answer THIS case - not how cautious you feel. '
        + 'Use HIGH when the solutions directly and completely answer the case and your draft faithfully '
        + 'conveys them. Use MEDIUM when they answer it but with a minor gap or an assumption the reviewer '
        + 'should check. Use LOW only when the solutions partially fit or you had to guess. Do NOT pick LOW '
        + 'merely because the answer involves product configuration the solutions already explain.\n'
        + '10. PRODUCT MATCH: S-Docs (document generation) and S-Sign (e-signature) are DISTINCT products '
        + 'with different setup, licensing, and menus. Each solution is tagged with its product and the '
        + 'case shows its PRODUCT. Do NOT answer using a solution whose product differs from the case '
        + 'product (e.g. do not give S-Docs License Key steps for an S-Sign licensing error). If the only '
        + 'fitting solutions are for the other product, set can_answer=false and say the correct-product '
        + 'guidance is missing. When the case PRODUCT is blank or lists both, use the solution whose '
        + 'product the case description actually concerns.\n'
        + '11. PERSONA: You are replying AS S-Docs Support - the customer has already reached us. '
        + 'Never tell the customer to "contact S-Docs", "reach out to S-Docs Support", or contact '
        + 'the vendor; you are that contact. If a solution doc instructs the reader to contact '
        + 'S-Docs (docs are written for end users), convert it into an offer we fulfil ourselves - '
        + 'e.g. "just let us know and we can..." - or invite them to reply with the details needed.\n'
        + '\n'
        + 'FORMAT EXAMPLE - structure and tone ONLY. Never copy this example\'s product facts into a '
        + 'draft: every fact in YOUR draft must come from the solutions below.\n'
        + 'BAD (the flat, run-on style to avoid):\n'
        + '"Hi, Thank you for reaching out. To send a reminder you can open the Salesforce record that '
        + 'created the signature request and go to the S-Sign Envelopes related list and open the pending '
        + 'envelope and click Send Reminder for the signer who still needs to act which generates a fresh '
        + 'active signing link, alternatively you can enable Notifications in S-Sign Setup and set your '
        + 'reminder timing in the template\'s Expiration and Reminder Settings and make sure the S-Sign '
        + 'Notifications job is turned on. Please be advised that you may contact us for further '
        + 'assistance. Sincerely, The Support Team"\n'
        + 'GOOD (the target shape - greeting, warm opener, sectioned steps, friendly close, sign-off):\n'
        + 'Hi {first name},\n'
        + '\n'
        + 'Thanks for reaching out - happy to help you send a reminder in S-Sign!\n'
        + '\n'
        + 'To manually remind a signer who hasn\'t signed yet:\n'
        + '\n'
        + '1. Open the Salesforce record that created the signature request.\n'
        + '2. Go to the S-Sign Envelopes related list and open the pending envelope.\n'
        + '3. Click "Send Reminder" for the signer who still needs to act - this generates a fresh, '
        + 'active signing link for them.\n'
        + '\n'
        + 'If you\'d prefer reminders to go out automatically:\n'
        + '\n'
        + '1. Enable Notifications in S-Sign Setup.\n'
        + '2. Set your reminder timing in the template\'s Expiration and Reminder Settings.\n'
        + '3. Make sure the S-Sign Notifications job is turned on - it checks pending envelopes and '
        + 'sends reminders on your schedule.\n'
        + '\n'
        + 'Let us know if you\'d like a hand setting up automatic reminders, or if anything else comes '
        + 'up!\n'
        + '(The draft ENDS at the closing sentence above. In the example, {first name} stands for the '
        + 'customer\'s real first name - substitute it per rule 5a, never emit the placeholder literally. '
        + 'Do NOT add a "Sincerely" / sign-off, signature, call offer, or links - those are appended '
        + 'automatically per rule 5e.)';

    // ---- grounding / faithfulness ----

    public class GroundingResult {
        public Boolean blocked = false;
        public Boolean flagged = false;
        public String summary;
    }

    // Closing pleasantries carry no factual claim — grading them would false-flag grounded drafts.
    private static final List<String> GROUNDING_CLOSING_MARKERS = new List<String>{
        'reach out', 'feel free', 'let us know', 'do not hesitate', 'don\'t hesitate', 'happy to help',
        'here to help', 'glad to help', 'further assistance', 'further questions', 'any questions',
        'assist you further', 'if you have any', 'if you need'
    };

    private static Boolean isClosingPleasantry(String sentence) {
        if (String.isBlank(sentence)) { return true; }
        String s = sentence.toLowerCase();
        for (String m : GROUNDING_CLOSING_MARKERS) { if (s.contains(m)) { return true; } }
        return false;
    }

    private static final Set<String> GROUNDING_STOPWORDS = new Set<String>{
        'your','have','this','that','with','from','will','would','should','there','their','about','which',
        'these','those','here','when','what','please','thanks','thank','hello','regards','team','also',
        'into','then','than','they','them','were','been','being','because','while','where','could','some'
    };

    /**
     * Deterministic sentence-overlap faithfulness check. Lexical, not semantic: a paraphrased answer can
     * score low (false-positive risk), so it is tuned to FLAG and only hard-blocks on very low grounding.
     */
    @TestVisible
    private static GroundingResult checkGrounding(String draftText, List<SolutionContext> fed, Config cfg) {
        GroundingResult g = new GroundingResult();
        if (cfg == null || !cfg.groundingEnabled || String.isBlank(draftText)) { return g; }

        Set<String> srcTokens = new Set<String>();
        if (fed != null) {
            for (SolutionContext s : fed) {
                if (s == null) { continue; }
                addContentTokens(srcTokens, s.body);
                addContentTokens(srcTokens, s.name);
            }
        }
        if (srcTokens.isEmpty()) { return g; } // nothing to verify against -> do not block
        Set<String> srcStems = new Set<String>();
        for (String t : srcTokens) { srcStems.add(stem(t)); }

        Integer evaluated = 0;
        Integer supported = 0;
        List<String> weak = new List<String>();
        for (String sentence : draftText.split('(?<=[.!?])\\s+|\\n+')) {
            if (isClosingPleasantry(sentence)) { continue; }
            if (sentence.trim().endsWith(':')) { continue; } // section-intro label; the steps are graded
            Set<String> toks = new Set<String>();
            addContentTokens(toks, sentence);
            if (toks.size() < 4) { continue; } // greetings/short lines carry no factual claim
            evaluated++;
            Integer hit = 0;
            for (String t : toks) { if (srcStems.contains(stem(t))) { hit++; } }
            Double overlap = ((Double) hit) / toks.size();
            if (overlap >= cfg.groundingMinOverlap) { supported++; }
            else if (weak.size() < 3) { weak.add(oneLineClip(sentence, 90)); }
        }
        if (evaluated == 0) { return g; }

        Double ratio = ((Double) supported) / evaluated;
        g.flagged = supported < evaluated;
        g.blocked = ratio < cfg.groundingBlockRatio;
        g.summary = supported + '/' + evaluated + ' draft sentences trace to cited sources (overlap >= '
            + round2(cfg.groundingMinOverlap) + ')'
            + (weak.isEmpty() ? '' : '; weak: "' + String.join(weak, '" | "') + '"');
        return g;
    }

    public class UrlScrubResult {
        public String text;
        public Integer removed = 0;
    }

    /**
     * Remove URLs the model emitted that do not appear in any fed source (its `url` or a link in its
     * body) — i.e. fabricated links. Leaves grounded links intact. Real documentation links are appended
     * deterministically by the footer, so removing a hallucinated one loses nothing.
     */
    @TestVisible
    private static UrlScrubResult scrubUngroundedUrls(String draftText, List<SolutionContext> fed) {
        UrlScrubResult r = new UrlScrubResult();
        r.text = draftText;
        if (String.isBlank(draftText)) { return r; }

        Pattern urlPat = Pattern.compile('(?i)https?://[^\\s\\)\\]<>"]+');
        Set<String> srcUrls = new Set<String>();
        if (fed != null) {
            for (SolutionContext s : fed) {
                if (s == null) { continue; }
                if (String.isNotBlank(s.url)) { srcUrls.add(normalizeUrl(s.url)); }
                Matcher mb = urlPat.matcher(nz(s.body));
                while (mb.find()) { srcUrls.add(normalizeUrl(mb.group())); }
            }
        }

        String out = draftText;
        Matcher md = urlPat.matcher(draftText);
        Set<String> badUrls = new Set<String>();
        while (md.find()) {
            String u = md.group();
            if (!srcUrls.contains(normalizeUrl(u))) { badUrls.add(u); }
        }
        for (String u : badUrls) {
            out = out.replace(u, '');
            r.removed++;
        }
        if (r.removed > 0) {
            // Tidy leftovers: empty "( )" / "[label]( )" wrappers and doubled spaces from the removed link.
            out = out.replaceAll('\\[[^\\]]*\\]\\(\\s*\\)', '');
            out = out.replaceAll('\\(\\s*\\)', '');
            out = out.replaceAll('[ \\t]{2,}', ' ');
        }
        r.text = out;
        return r;
    }

    /** Lowercase + trim trailing punctuation / slash so draft and source URLs compare equal. */
    private static String normalizeUrl(String u) {
        if (u == null) { return ''; }
        String s = u.trim().toLowerCase();
        s = s.replaceAll('[\\.,;:\\)\\]]+$', '');
        if (s.endsWith('/')) { s = s.substring(0, s.length() - 1); }
        return s;
    }

    // ---- claim-level fabrication check (deterministic) ----

    public class ClaimResult {
        public Boolean ok = true;
        public List<String> unverified = new List<String>();
    }

    // Concrete, verifiable specifics — the "hard facts" a fabrication tends to invent. Deliberately the
    // high-signal, low-false-positive classes: each is a single contiguous token that a FAITHFUL draft only
    // contains because it copied it from a source, so a token missing from every source is a fabrication.
    // (Multi-word menu paths / bare small numbers are intentionally excluded — too paraphrase-prone; the
    //  LLM verification gate covers those softer cases.)
    private static final Pattern CLAIM_API_NAME =
        Pattern.compile('(?i)[a-z][a-z0-9_]*__[crembx]\\b');                  // SSIC_Policy__c, SDOC__Has_Error__c
    private static final Pattern CLAIM_CAMEL =
        Pattern.compile('\\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\\b');           // GenerateDocumentInvocable
    private static final Pattern CLAIM_BACKTICK = Pattern.compile('`([^`]+)`'); // `format-number`
    private static final Pattern CLAIM_ATTR =
        Pattern.compile('[a-zA-Z_][a-zA-Z0-9_-]*=\'[^\']+\'');                // autoopen='newtab'
    private static final Pattern CLAIM_MERGE = Pattern.compile('\\{\\{![^}]+\\}\\}'); // {{!SDOCS_JAVASCRIPT}}
    private static final Pattern CLAIM_NUMBER =
        Pattern.compile('\\bv?\\d+\\.\\d+(?:\\.\\d+)*\\b|\\b\\d{3,}\\b');      // v6.1.10, 500 (not step ordinals)
    // Back-ticked span triage (measured FPs 00033725/00033844/00033957): a span that is an HTML/CSS
    // markup example, or that is plain prose (backtick pairing drift grabs the text BETWEEN two
    // adjacent code spans), must not be containment-checked as one contiguous token.
    private static final Pattern SPAN_MARKUP =
        Pattern.compile('(?i)^\\s*<[a-z][^>]*>|style="');                     // <img style="...">, <b ...>
    private static final Pattern SPAN_CODE_SIGNAL =
        Pattern.compile('[=:;{}<>]|\\b[A-Z]{2,}\\b|[A-Z][a-z0-9]+[A-Z]|__');  // assignments, SOQL/keywords, CamelCase, API names

    /**
     * Every concrete specific in the draft must trace to a cited source or the customer's own case text
     * (echoing the customer isn't fabrication). Comparison is normalized substring containment
     * (case-insensitive, non-alphanumerics stripped) so `SSIC_Policy__c` matches only a source that
     * actually contains that identifier. Deterministic; no model call.
     */
    @TestVisible
    private static ClaimResult checkClaims(
            String draftText, List<SolutionContext> fed, DraftInput input, Config cfg) {
        ClaimResult r = new ClaimResult();
        if (cfg == null || !cfg.claimCheckEnabled || String.isBlank(draftText)) { return r; }

        String hay = '';
        if (fed != null) {
            for (SolutionContext s : fed) {
                if (s == null) { continue; }
                hay += ' ' + nz(s.body) + ' ' + nz(s.name);
            }
        }
        if (input != null) { hay += ' ' + nz(input.caseSubject) + ' ' + nz(input.caseDescription); }
        String normHay = normClaim(hay);

        Set<String> seen = new Set<String>();
        for (String tok : extractConcreteTokens(draftText)) {
            String nt = normClaim(tok);
            if (nt.length() < 2) { continue; }               // too short to be a meaningful specific
            if (normHay.contains(nt)) { continue; }          // supported by a source or the customer
            if (seen.add(nt)) { r.unverified.add(tok.trim()); }
        }
        Integer tol = (cfg.claimCheckMaxUnverified == null) ? 0 : cfg.claimCheckMaxUnverified;
        r.ok = r.unverified.size() <= tol;
        return r;
    }

    @TestVisible
    private static List<String> extractConcreteTokens(String draftText) {
        List<String> out = new List<String>();
        if (String.isBlank(draftText)) { return out; }
        for (Pattern p : new List<Pattern>{
                CLAIM_API_NAME, CLAIM_CAMEL, CLAIM_ATTR, CLAIM_MERGE, CLAIM_NUMBER }) {
            Matcher m = p.matcher(draftText);
            while (m.find()) { out.add(m.group()); }
        }
        // Back-ticked spans: verify the inner content (the code/label the model quoted) — except
        // markup examples and prose. An HTML/CSS span is usually an illustration legitimately
        // COMPOSED from documented techniques, and a prose span is backtick pairing drift (the text
        // between two adjacent code spans); whole-span containment flags good drafts on both. Their
        // concrete sub-tokens (API names, identifiers, versions) are still verified individually by
        // the pattern loop above, and structural inventions such as fabricated query syntax carry
        // code-signal characters, so they keep strict whole-span matching.
        Matcher mb = CLAIM_BACKTICK.matcher(draftText);
        while (mb.find()) {
            String span = mb.group(1);
            if (SPAN_MARKUP.matcher(span).find()) { continue; }
            Boolean prose = span.trim().split('\\s+').size() >= 4
                && !SPAN_CODE_SIGNAL.matcher(span).find();
            if (prose) { continue; }
            out.add(span);
        }
        return out;
    }

    private static String normClaim(String s) {
        return (s == null) ? '' : s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }

    // ---- LLM verification gate (second, cheap model call) ----

    public class VerifyResult {
        public Boolean approved = false;
        public Boolean called = false;
        public Boolean parsed = false;       // the response parsed to JSON: a non-approval is an affirmative decline
        public Boolean claimsJudged = false; // the judge answered the fabrication question; fabricated is meaningful
        public Boolean fabricated = false;   // judge's fabricated_specifics verdict: concrete invented facts
        public String reason;
    }

    /**
     * One cheap second-model call that must APPROVE the draft, or it is declined. Fail closed: a disabled
     * gate passes through, but once enabled every non-approval path (false verdict, missing/uncertain
     * fields, unparseable response, empty response, thrown callout) returns approved=false. No retry — a
     * retry loop would just resample until it passed, defeating the gate.
     */
    @TestVisible
    private static VerifyResult verifyDraft(
            String draftText, DraftInput input, List<SolutionContext> fed, Config cfg) {
        VerifyResult v = new VerifyResult();
        if (cfg == null || !cfg.verifyEnabled) { v.approved = true; return v; } // gate off -> pass through

        String prompt = buildVerifyPrompt(draftText, input, fed);
        String raw = null;
        try {
            raw = client.generate(cfg.verifyModelName, prompt);
            v.called = true;
        } catch (Exception e) {
            v.reason = 'verification callout failed: ' + e.getMessage();
            return v; // fail closed
        }
        if (String.isBlank(raw)) { v.reason = 'verification returned an empty response'; return v; }

        Map<String, Object> parsed = parseJson(raw);
        if (parsed.isEmpty()) { v.reason = 'verification response was unparseable'; return v; }
        v.parsed = true;

        Boolean answers = boolValue(parsed, 'answers_specific_question', false);
        Boolean supported = boolValue(parsed, 'all_claims_supported', false);
        v.claimsJudged = parsed.containsKey('fabricated_specifics');
        v.fabricated = boolValue(parsed, 'fabricated_specifics', false);
        String verdict = stringValue(parsed, 'verdict');
        v.reason = stringValue(parsed, 'reason');
        v.approved = answers && supported
            && 'approve'.equalsIgnoreCase(verdict == null ? '' : verdict.trim());
        if (!v.approved && String.isBlank(v.reason)) {
            v.reason = 'draft did not meet both verification criteria';
        }
        return v;
    }

    @TestVisible
    private static String buildVerifyPrompt(
            String draftText, DraftInput input, List<SolutionContext> fed) {
        String sources = '';
        Integer n = 1;
        if (fed != null) {
            for (SolutionContext s : fed) {
                if (s == null) { continue; }
                sources += '[' + n + '] ' + nz(s.name) + ':\n' + nz(s.body) + '\n\n';
                n++;
            }
        }
        return
            'You are a strict support-QA reviewer. Decide whether a drafted reply may be sent.\n'
            + 'Approve ONLY if BOTH are true:\n'
            + '  (1) The draft addresses the customer\'s SPECIFIC problem/question as stated - not merely '
            + 'the general topic. If the specific error/question is not actually present in the CASE text '
            + '(e.g. it appears to live in an unshown screenshot/attachment), you cannot confirm the draft '
            + 'answers it - do not approve.\n'
            + '  (2) Every concrete claim in the draft (steps, causes, field/setting names, values, syntax, '
            + 'limits) is supported by the SOURCES below. Anything not supported - do not approve.\n'
            + 'When uncertain, DO NOT APPROVE. Reply with JSON only.\n'
            + 'SEPARATELY, judge fabricated_specifics: set it true ONLY if the draft states a concrete '
            + 'fact - a limit, number, time period, API/field/setting name, code or merge syntax, menu '
            + 'path, or specific product behavior - that appears in NEITHER the SOURCES NOR the '
            + 'customer\'s own case text. Generic advice, hedged suggestions, or prose that merely goes '
            + 'beyond the sources WITHOUT asserting an invented concrete fact is NOT fabrication: in '
            + 'those cases set fabricated_specifics false (even while declining).\n\n'
            + 'CASE SUBJECT: ' + nz(input == null ? null : input.caseSubject) + '\n'
            + 'CASE DESCRIPTION:\n' + nz(input == null ? null : input.caseDescription) + '\n\n'
            + 'DRAFT REPLY:\n' + nz(draftText) + '\n\n'
            + 'SOURCES (the only permissible basis for claims):\n' + sources
            + '=== OUTPUT ===\n'
            + 'Return ONLY a strict JSON object with exactly these fields:\n'
            + '{"answers_specific_question": true or false, "all_claims_supported": true or false, '
            + '"fabricated_specifics": true or false, '
            + '"verdict": "approve" or "decline", "reason": "one sentence"}';
    }

    private static void addContentTokens(Set<String> bag, String text) {
        if (String.isBlank(text)) { return; }
        for (String raw : text.toLowerCase().split('[^a-z0-9]+')) {
            if (raw.length() >= 4 && !GROUNDING_STOPWORDS.contains(raw)) { bag.add(raw); }
        }
    }

    /** Crude plural stem so surface morphology isn't mistaken for an ungrounded claim. */
    private static String stem(String t) {
        return (t != null && t.length() > 4 && t.endsWith('s')) ? t.substring(0, t.length() - 1) : t;
    }

    private static String oneLineClip(String v, Integer max) {
        if (String.isBlank(v)) { return ''; }
        String s = v.replaceAll('\\s+', ' ').trim();
        return s.length() > max ? s.substring(0, max) + '...' : s;
    }

    private static String round2(Double d) {
        if (d == null) { return 'n/a'; }
        return String.valueOf(Decimal.valueOf(d).setScale(2, System.RoundingMode.HALF_UP));
    }

    /** Appends the deterministic reply footer: doc links of the solutions used, then the call offer. */
    @TestVisible
    private static String appendReplyFooter(
            String draftText, List<SolutionContext> fed, String sourcesUsed, Config cfg) {
        if (String.isBlank(draftText)) { return draftText; }

        List<String> blocks = new List<String>();

        String docs = buildDocLinks(fed, sourcesUsed);
        if (String.isNotBlank(docs)) { blocks.add(docs); }

        if (cfg != null && String.isNotBlank(cfg.callOfferText)) { blocks.add(cfg.callOfferText.trim()); }

        return blocks.isEmpty() ? draftText : draftText + '\n\n' + String.join(blocks, '\n\n');
    }

    /** Doc-links block: links of the solutions the model used; blank/unmatched -> all fed links. */
    @TestVisible
    private static String buildDocLinks(List<SolutionContext> fed, String sourcesUsed) {
        if (fed == null || fed.isEmpty()) { return null; }

        Set<String> used = new Set<String>();
        if (String.isNotBlank(sourcesUsed)) {
            for (String id : sourcesUsed.split(',')) {
                String t = (id == null) ? '' : id.trim();
                if (t != '') { used.add(t); }
            }
        }

        List<String> lines = collectDocLines(fed, used);
        if (lines.isEmpty() && !used.isEmpty()) { lines = collectDocLines(fed, new Set<String>()); }
        if (lines.isEmpty()) { return null; }

        return 'You may also find these resources helpful:\n' + String.join(lines, '\n');
    }

    private static List<String> collectDocLines(List<SolutionContext> fed, Set<String> onlyIds) {
        List<String> lines = new List<String>();
        Set<String> seenUrls = new Set<String>();
        for (SolutionContext s : fed) {
            if (s == null || String.isBlank(s.url)) { continue; }
            if (!onlyIds.isEmpty() && (s.solutionId == null || !onlyIds.contains(s.solutionId))) { continue; }
            String url = s.url.trim();
            if (!seenUrls.add(url)) { continue; }
            String title = String.isBlank(s.name) ? url : s.name.trim();
            lines.add('- ' + title + ': ' + url);
        }
        return lines;
    }

    /** Appends required disclaimers verbatim (fetched by Id when not inline), de-duplicated. */
    @TestVisible
    private static String appendDisclaimers(String draftText, List<SolutionContext> fed) {
        if (String.isBlank(draftText)) { return draftText; }

        Map<String, String> textById = new Map<String, String>();
        Set<Id> fetchIds = new Set<Id>();
        for (SolutionContext s : fed) {
            if (s == null || s.hasRequiredDisclaimer != true) { continue; }
            if (!String.isBlank(s.requiredDisclaimerText)) {
                textById.put(s.solutionId, s.requiredDisclaimerText.trim());
            } else if (!String.isBlank(s.solutionId)) {
                try { fetchIds.add((Id) s.solutionId); } catch (Exception e) { /* not a real Id */ }
            }
        }
        if (!fetchIds.isEmpty()) {
            for (Support_Solution__c r : [
                    SELECT Id, Required_Disclaimer_Text__c FROM Support_Solution__c
                    WHERE Id IN :fetchIds AND Has_Required_Disclaimer__c = true]) {
                if (!String.isBlank(r.Required_Disclaimer_Text__c)) {
                    textById.put(String.valueOf(r.Id), r.Required_Disclaimer_Text__c.trim());
                }
            }
        }
        if (textById.isEmpty()) { return draftText; }

        List<String> added = new List<String>();
        Set<String> seen = new Set<String>();
        for (SolutionContext s : fed) {
            String t = (s == null) ? null : textById.get(s.solutionId);
            if (!String.isBlank(t) && seen.add(t)) { added.add(t); }
        }
        return added.isEmpty() ? draftText : draftText + '\n\n' + String.join(added, '\n\n');
    }

    /** Shared model-JSON parsing (bare/fenced/prose-carved) lives on EinsteinAiClient; this keeps
     *  draft()'s "unparseable = empty map" convention. */
    @TestVisible
    private static Map<String, Object> parseJson(String responseBody) {
        Map<String, Object> parsed = EinsteinAiClient.parseModelJson(responseBody);
        return (parsed == null) ? new Map<String, Object>() : parsed;
    }

    private static String stringValue(Map<String, Object> m, String key) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) { return null; }
        return String.valueOf(m.get(key));
    }

    @TestVisible
    private static Boolean boolValue(Map<String, Object> m, String key, Boolean defaultVal) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) { return defaultVal; }
        Object v = m.get(key);
        if (v instanceof Boolean) { return (Boolean) v; }
        String s = String.valueOf(v).trim().toLowerCase();
        if (s == 'true') { return true; }
        if (s == 'false') { return false; }
        return defaultVal;
    }

    @TestVisible
    private static String normalizeConfidence(String c) {
        if (String.isBlank(c)) { return 'MEDIUM'; }
        String u = c.trim().toUpperCase();
        if (u == 'HIGH' || u == 'MEDIUM' || u == 'LOW' || u == 'NONE') { return u; }
        return 'MEDIUM';
    }

    // Generation can never be more confident than the evidence it was built on.
    @TestVisible
    private static String clampConfidence(String modelConfidence, String retrievalConfidence) {
        Integer m = rank(modelConfidence);
        Integer r = rank(retrievalConfidence);
        Integer lower = (m < r) ? m : r;
        return fromRank(lower);
    }

    @TestVisible
    private static String raiseTo(String confidence, String floor) {
        if (String.isBlank(floor) || 'NONE'.equalsIgnoreCase(floor.trim())) { return confidence; }
        Integer c = rank(confidence);
        Integer f = rank(floor);
        return fromRank((c > f) ? c : f);
    }

    private static Integer rank(String c) {
        String u = String.isBlank(c) ? 'NONE' : c.trim().toUpperCase();
        if (u == 'HIGH') { return 3; }
        if (u == 'MEDIUM') { return 2; }
        if (u == 'LOW') { return 1; }
        return 0;
    }

    private static String fromRank(Integer r) {
        if (r == 3) { return 'HIGH'; }
        if (r == 2) { return 'MEDIUM'; }
        if (r == 1) { return 'LOW'; }
        return 'NONE';
    }

    // Trust labels shown to the model; mirrors SupportRetrievalService.trustWeight's ladder.
    private static String trustLabel(String src) {
        if (src == 'official' || src == 'canned') { return 'highest'; }
        if (src == 'tribal' || src == 'tips') { return 'high'; }
        if (src == 'unsorted') { return 'medium'; }
        return 'low'; // draft / internal_ops / query / null / unknown
    }

    /**
     * Structured reviewer note: Explanation / Confidence (+why) / Source used / Top sources considered.
     * Callers append status flags ([grounding ...], [model declined ...]) as extra lines below.
     */
    private static String buildNotes(String agentNotes, String sourcesUsed, String confidence,
            String confidenceWhy, List<SolutionContext> fed) {
        List<String> lines = new List<String>();
        lines.add('Explanation: '
            + (String.isBlank(agentNotes) ? '(none provided by the model)' : agentNotes.trim()));
        lines.add('Confidence: ' + confidence
            + (String.isBlank(confidenceWhy) ? '' : ' - ' + confidenceWhy.trim()));
        lines.add('Source used: ' + describePrimarySource(sourcesUsed, fed));
        String considered = describeTopConsidered(fed, 3);
        if (!String.isBlank(considered)) {
            lines.add('Top sources considered:');
            lines.add(considered);
        }
        return String.join(lines, '\n');
    }

    private static String describePrimarySource(String sourcesUsed, List<SolutionContext> fed) {
        List<String> ids = new List<String>();
        if (!String.isBlank(sourcesUsed)) {
            for (String raw : sourcesUsed.split(',')) {
                String id = (raw == null) ? '' : raw.trim();
                if (id != '') { ids.add(id); }
            }
        }
        if (ids.isEmpty()) { return '(model reported no sources)'; }
        String primary = describeSources(ids[0], fed);
        if (ids.size() > 1) {
            ids.remove(0);
            primary += ' (also used: ' + describeSources(String.join(ids, ','), fed) + ')';
        }
        return primary;
    }

    private static String describeTopConsidered(List<SolutionContext> fed, Integer maxN) {
        if (fed == null || fed.isEmpty()) { return ''; }
        List<String> lines = new List<String>();
        for (Integer i = 0; i < fed.size() && i < maxN; i++) {
            SolutionContext s = fed[i];
            if (s == null) { continue; }
            String line = (i + 1) + '. ' + oneLineClip(nz(s.name), 80);
            if (s.relevanceScore != null) { line += ' (score ' + round2(s.relevanceScore) + ')'; }
            if (!String.isBlank(s.url)) { line += ' - ' + s.url.trim(); }
            if (!String.isBlank(s.solutionId)) { line += ' (' + s.solutionId.trim() + ')'; }
            lines.add(line);
        }
        return String.join(lines, '\n');
    }

    /** Resolve sources_used ids to "Title - url (id)"; unmatched ids are kept raw, never hidden. */
    private static String describeSources(String sourcesUsed, List<SolutionContext> fed) {
        Map<String, SolutionContext> byId = new Map<String, SolutionContext>();
        if (fed != null) {
            for (SolutionContext s : fed) {
                if (s != null && !String.isBlank(s.solutionId)) { byId.put(s.solutionId.trim(), s); }
            }
        }
        List<String> parts = new List<String>();
        for (String raw : sourcesUsed.split(',')) {
            String id = (raw == null) ? '' : raw.trim();
            if (id == '') { continue; }
            SolutionContext s = byId.get(id);
            if (s == null || String.isBlank(s.name)) {
                parts.add(id);
                continue;
            }
            String part = oneLineClip(s.name, 80);
            if (!String.isBlank(s.url)) { part += ' - ' + s.url.trim(); }
            part += ' (' + id + ')';
            parts.add(part);
        }
        return String.join(parts, ' | ');
    }

    private static String nz(String s) { return s == null ? '' : s; }

    private static String truncate(String s, Integer max) {
        if (s == null) { return ''; }
        return (s.length() > max) ? s.substring(0, max) + '...' : s;
    }

    private static Config loadConfig() {
        Config c = new Config();
        Support_Draft_Setting__mdt s = Support_Draft_Setting__mdt.getInstance('Default');
        if (s != null) {
            if (!String.isBlank(s.Drafting_Model_Name__c)) { c.modelName = s.Drafting_Model_Name__c; }
            if (!String.isBlank(s.Draft_Prompt_Instructions__c)) { c.promptInstructions = s.Draft_Prompt_Instructions__c; }
            if (s.Draft_Max_Solutions__c != null) { c.maxSolutions = (Integer) s.Draft_Max_Solutions__c; }
            if (s.Draft_Solution_Char_Limit__c != null) { c.solutionCharLimit = (Integer) s.Draft_Solution_Char_Limit__c; }
            if (s.Draft_Max_Retries__c != null) { c.maxRetries = (Integer) s.Draft_Max_Retries__c; }
            if (s.Draft_Min_Top_Score__c != null) { c.minTopScore = s.Draft_Min_Top_Score__c.doubleValue(); }
            if (s.Draft_Grounding_Enabled__c != null) { c.groundingEnabled = s.Draft_Grounding_Enabled__c; }
            if (s.Draft_Grounding_Min_Overlap__c != null) { c.groundingMinOverlap = s.Draft_Grounding_Min_Overlap__c.doubleValue(); }
            if (s.Draft_Grounding_Block_Ratio__c != null) { c.groundingBlockRatio = s.Draft_Grounding_Block_Ratio__c.doubleValue(); }
            if (!String.isBlank(s.Draft_Drafted_Conf_Floor__c)) { c.draftedConfFloor = s.Draft_Drafted_Conf_Floor__c.trim(); }
            if (!String.isBlank(s.Draft_Call_Offer_Text__c)) { c.callOfferText = s.Draft_Call_Offer_Text__c; }
            if (s.Draft_Claim_Check_Enabled__c != null) { c.claimCheckEnabled = s.Draft_Claim_Check_Enabled__c; }
            if (s.Draft_Claim_Check_Max_Unverified__c != null) { c.claimCheckMaxUnverified = (Integer) s.Draft_Claim_Check_Max_Unverified__c; }
            if (s.Draft_Verify_Enabled__c != null) { c.verifyEnabled = s.Draft_Verify_Enabled__c; }
            if (!String.isBlank(s.Draft_Verify_Model__c)) { c.verifyModelName = s.Draft_Verify_Model__c; }
            if (!String.isBlank(s.Draft_Gate_Mode__c)) { c.gateMode = s.Draft_Gate_Mode__c.trim().toLowerCase(); }
            if (s.Draft_Structural_Decline_Enabled__c != null) { c.structuralDeclineEnabled = s.Draft_Structural_Decline_Enabled__c; }
            if (s.Draft_Verify_Second_Vote__c != null) { c.verifySecondVote = s.Draft_Verify_Second_Vote__c; }
        }
        if (Test.isRunningTest() && testForceGrounding != null) {
            c.groundingEnabled = testForceGrounding;
        }
        // CMDT is visible in test context, so the two precision gates default OFF under Test (leaving the
        // existing DRAFTED tests unaffected) and are opt-in per test via the testForce* overrides.
        if (Test.isRunningTest()) {
            c.claimCheckEnabled = (testForceClaimCheck == true);
            c.verifyEnabled = (testForceVerify == true);
            c.structuralDeclineEnabled = (testForceStructuralDecline == true);
            c.verifySecondVote = (testForceVerifySecondVote == true);
            if (testForceVerifyModel != null) { c.verifyModelName = testForceVerifyModel; }
            // Default 'block' under test so the fail-closed gate tests stay authoritative.
            c.gateMode = (testForceGateMode != null)
                ? testForceGateMode : SupportDraftVocab.GATE_MODE_BLOCK;
        }
        return c;
    }
}
