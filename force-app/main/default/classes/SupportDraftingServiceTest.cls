/**
 * The Models call is stubbed via the ModelClient seam; the stub records call count + prompt so
 * the guardrails and prompt assembly are both asserted.
 */
@isTest
private class SupportDraftingServiceTest {

    // ---- stub model client ----
    private class StubClient implements SupportDraftingService.ModelClient {
        String response;
        Boolean throwIt = false;
        public Boolean called = false;
        public String lastPrompt;
        public String lastModel;
        StubClient(String r) { this.response = r; }
        public String generate(String modelName, String prompt) {
            called = true;
            lastPrompt = prompt;
            lastModel = modelName;
            if (throwIt) { throw new CalloutException('simulated callout failure'); }
            return response;
        }
    }

    private static SupportDraftingService.SolutionContext sol(
            String id, String name, String src, String body) {
        SupportDraftingService.SolutionContext s = new SupportDraftingService.SolutionContext();
        s.solutionId = id;
        s.name = name;
        s.sourceType = src;
        s.visibility = 'customer_safe'; // default to draftable; tests override to exercise the gate
        s.solutionType = 'explainer';
        s.url = 'https://example.atlassian.net/wiki/' + id;
        s.body = body;
        return s;
    }

    private static SupportDraftingService.DraftInput baseInput() {
        SupportDraftingService.DraftInput in1 = new SupportDraftingService.DraftInput();
        in1.caseSubject = 'Merge fields blank';
        in1.caseDescription = 'My generated document shows blank merge fields.';
        in1.product = 'S-Docs';
        in1.customerName = 'Dana';
        in1.retrievalConfidence = 'HIGH';
        in1.solutions = new List<SupportDraftingService.SolutionContext>{
            sol('a01', 'Merge fields not populating', 'canned',
                'Check that the field API names in the template match the object.')
        };
        return in1;
    }

    private static String okJson() {
        return '{"draft":"Hi Dana, please verify the field API names in your template match the object. ",'
            + '"sources_used":"a01","agent_notes":"Standard fix.","confidence":"HIGH"}';
    }

    @isTest
    static void excludedShortCircuitsBeforeModelCall() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.excluded = true;
        in1.excludedReason = 'refund request';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_EXCLUDED', r.status);
        System.assertEquals('NONE', r.confidence);
        System.assertEquals(null, r.draftText);
        System.assertEquals(false, stub.called, 'Excluded case must NOT call the model');
        System.assert(r.notes.contains('refund'), 'Reason surfaced: ' + r.notes);
    }

    @isTest
    static void noMatchShortCircuitsBeforeModelCall() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.retrievalConfidence = 'NONE';
        in1.solutions = new List<SupportDraftingService.SolutionContext>();

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_NO_MATCH', r.status);
        System.assertEquals('NONE', r.confidence);
        System.assertEquals(false, stub.called, 'No-match case must NOT call the model');
    }

    @isTest
    static void happyPathDrafts() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status);
        System.assert(r.draftText.startsWith('Hi Dana'), 'Draft text returned: ' + r.draftText);
        System.assertEquals('HIGH', r.confidence);
        System.assertEquals(1, r.sourceIds.size());
        System.assertEquals('a01', r.sourceIds[0]);
        System.assertEquals('sfdc_ai__DefaultGPT4Omni', r.modelName);
        System.assert(stub.called, 'Model should be called on a draftable case');
        // prompt carries the trust ladder + the strict JSON output contract
        System.assert(stub.lastPrompt.contains('canned'), 'Prompt includes source_type');
        System.assert(stub.lastPrompt.contains('"draft"'), 'Prompt states the JSON output contract');
        System.assert(stub.lastPrompt.contains('Merge fields blank'), 'Prompt carries the case subject');
    }

    @isTest
    static void notesAreStructuredForTheReviewer() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].relevanceScore = 0.62;
        in1.solutions.add(sol('a02', 'Template setup guide', 'tips',
            'General template setup steps.'));
        in1.solutions[1].relevanceScore = 0.41;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status);
        List<String> lines = r.notes.split('\n');
        System.assert(lines[0].startsWith('Explanation: Standard fix.'),
            'Line 1 is the model\'s explanation: ' + r.notes);
        System.assert(lines[1].startsWith('Confidence: HIGH - model reported HIGH, retrieval evidence HIGH'),
            'Line 2 is the confidence + its derivation: ' + r.notes);
        System.assertEquals(
            'Source used: Merge fields not populating - https://example.atlassian.net/wiki/a01 (a01)',
            lines[2], 'Line 3 is the primary source with title + link + id: ' + r.notes);
        System.assertEquals('Top sources considered:', lines[3], r.notes);
        System.assert(lines[4].startsWith('1. Merge fields not populating (score 0.62)'),
            'Considered sources are ranked and carry the retrieval score: ' + r.notes);
        System.assert(lines[5].startsWith('2. Template setup guide (score 0.41)'),
            'The runner-up candidate is listed too: ' + r.notes);
    }

    @isTest
    static void confidenceClampedToRetrieval() {
        // Model claims HIGH but retrieval was only MEDIUM -> draft cannot exceed MEDIUM.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.retrievalConfidence = 'MEDIUM';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status);
        System.assertEquals('MEDIUM', r.confidence, 'Generation cannot be more confident than retrieval');
    }

    @isTest
    static void emptyGenerationRoutesToHuman() {
        StubClient stub = new StubClient('```json\n{"draft":"   ","confidence":"HIGH"}\n```');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_MODEL_ERROR', r.status,
            'A parseable-but-empty draft with no explanation is a model error, not a decline');
        System.assertEquals('LOW', r.confidence);
        System.assertEquals(null, r.draftText);
    }

    @isTest
    static void modelDeclineKeepsReasonAndCapsConfidence() {
        // Model PARSES cleanly but returns an empty draft WITH an explanation -> a deliberate decline
        // (prompt rule 3), not a failure. Must be NO_DRAFT_LOW_CONFIDENCE (distinct from NO_DRAFT_ERROR),
        // keep the model's "what is missing" reason, and cap confidence at LOW even though the model
        // claimed MEDIUM (a decline is never a confident outcome).
        StubClient stub = new StubClient(
            '```json\n{"draft":"","sources_used":"a01",'
            + '"agent_notes":"The solutions cover setup but not this specific error code.",'
            + '"confidence":"MEDIUM"}\n```');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status,
            'A parseable empty draft with a reason is a decline, not an error');
        System.assertEquals('LOW', r.confidence, 'A decline is capped at LOW regardless of the model claim');
        System.assertEquals(null, r.draftText);
        System.assert(stub.called, 'The decline is a real model outcome -> the model was called');
        System.assert(r.notes.contains('specific error code'),
            'The model\'s "what is missing" reason is preserved: ' + r.notes);
        System.assert(r.notes.contains('declined'), 'Notes mark it as a decline: ' + r.notes);
    }

    @isTest
    static void garbledGenerationRoutesToHuman() {
        StubClient stub = new StubClient('not json at all <<>>');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_MODEL_ERROR', r.status);
        System.assertEquals('LOW', r.confidence);
    }

    @isTest
    static void calloutFailureRoutesToHuman() {
        StubClient stub = new StubClient(okJson());
        stub.throwIt = true;
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_MODEL_ERROR', r.status,
            'A callout that keeps throwing after retries is a model error, distinct from a decline');
        System.assertEquals('LOW', r.confidence);
        System.assert(r.notes.contains('failed'), 'Failure surfaced: ' + r.notes);
        System.assert(r.notes.contains('attempt'), 'Notes report the retry attempts: ' + r.notes);
    }

    @isTest
    static void capsSolutionsFed() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions = new List<SupportDraftingService.SolutionContext>();
        for (Integer i = 0; i < 6; i++) {
            in1.solutions.add(sol('id' + i, 'Sol ' + i, 'tips', 'body ' + i));
        }

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        // #4: cap raised 3 -> 5 (match retrieval's selection ceiling). 6 short solutions -> 5 fed (count
        // ceiling, well under the total char budget). Retrieval already trims the weak tail upstream.
        System.assertEquals(5, r.sourceIds.size(), 'maxSolutions ceiling (5) should bound fed solutions');
    }

    @isTest
    static void explicitCanAnswerFalseRoutesToHuman() {
        // #4: the model can DECLARE the docs insufficient (can_answer=false) even while returning a draft
        // string. That structured decline is honoured: no draft goes out, the 'missing' reason is kept,
        // confidence capped at LOW. This replaces inferring a decline only from an empty draft.
        StubClient stub = new StubClient(
            '```json\n{"can_answer": false, "missing": "no doc covers the SDException error code", '
            + '"draft": "Hi Dana, here is a guess...", "sources_used": "a01", '
            + '"agent_notes": "partial", "confidence": "HIGH"}\n```');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status, 'can_answer=false is a decline');
        System.assertEquals(null, r.draftText, 'No draft goes out on an explicit cannot-answer');
        System.assertEquals('LOW', r.confidence, 'A decline is capped at LOW');
        System.assert(r.notes.contains('SDException error code'),
            'The missing reason is preserved: ' + r.notes);
        System.assert(r.notes.contains('cannot answer'), 'Notes mark the explicit decline: ' + r.notes);
    }

    @isTest
    static void relevanceScoreSurfacedInPrompt() {
        // #4: the retrieval relevance score must reach the prompt so generation sees the ranking separation.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;
        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].relevanceScore = 0.4793;
        SupportDraftingService.draft(in1);
        System.assert(stub.lastPrompt.contains('relevance: 0.4793'),
            'Relevance score must be surfaced to the model: ' + stub.lastPrompt);
        System.assert(stub.lastPrompt.contains('RETRIEVAL CONFIDENCE'),
            'Retrieval confidence must be stated in the prompt');
    }

    @isTest
    static void agentOnlySolutionsAreNotDrafted() {
        // Matches exist but none are customer_safe -> the safety gate blocks drafting, no model call.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        for (SupportDraftingService.SolutionContext s : in1.solutions) { s.visibility = 'agent_only'; }

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_NO_MATCH', r.status, 'Non-customer-safe matches must not be drafted');
        System.assertEquals('NONE', r.confidence);
        System.assertEquals(false, stub.called, 'Model must not be called without customer-safe fuel');
        System.assert(r.notes.contains('customer-safe'), 'Notes explain the gate: ' + r.notes);
    }

    @isTest
    static void requiredDisclaimerAppendedAfterGeneration() {
        // The model draft does NOT contain the disclaimer; it must still appear, appended verbatim.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        SupportDraftingService.SolutionContext s = in1.solutions[0];
        s.hasRequiredDisclaimer = true;
        s.requiredDisclaimerText = 'E-signatures are legally binding under the ESIGN Act.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status);
        System.assert(r.draftText.contains('ESIGN Act'),
            'Disclaimer must be appended verbatim after generation: ' + r.draftText);
        System.assert(r.notes.contains('disclaimer'), 'Notes flag the appended disclaimer: ' + r.notes);
    }

    @isTest
    static void templateSolutionDirectsFaithfulReproduction() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].solutionType = 'template';

        SupportDraftingService.draft(in1);

        System.assert(stub.lastPrompt.contains('solution_type: template'),
            'Prompt should carry the solution_type');
        System.assert(stub.lastPrompt.contains('reproduce faithfully'),
            'Template solutions should get a verbatim-reproduction directive');
    }

    // ---- reply footer: doc links + call offer (owner sign-off is applied later by the publisher) ----

    @isTest
    static void replyFooterAppendsDocLinksAndCallOffer() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status);
        // model body is still first
        System.assert(r.draftText.startsWith('Hi Dana'), 'Model body leads: ' + r.draftText);
        // 1. documentation link for the solution the model used (sources_used = a01 -> its url)
        System.assert(r.draftText.contains('https://example.atlassian.net/wiki/a01'),
            'The used solution\'s doc link is appended: ' + r.draftText);
        // 2. call offer with availability (from mdt or the class default; both share this phrase)
        System.assert(r.draftText.contains('hop on a call'),
            'Every reply offers a call with available times: ' + r.draftText);
        // 3. the sign-off/signature is NOT in the plain-text draft - the publisher owns it (HTML signature).
        System.assert(!r.draftText.contains('Sincerely'),
            'Sign-off is applied by the publisher, not baked into the draft body: ' + r.draftText);
    }

    @isTest
    static void footerDisclaimerComesAfterCallOffer() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].hasRequiredDisclaimer = true;
        in1.solutions[0].requiredDisclaimerText = 'E-signatures are legally binding under the ESIGN Act.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status);
        // legal disclaimer sits at the very bottom, AFTER the call offer
        Integer callIdx = r.draftText.indexOf('hop on a call');
        Integer legalIdx = r.draftText.indexOf('ESIGN Act');
        System.assert(callIdx >= 0 && legalIdx > callIdx,
            'Required disclaimer is appended after the call offer: ' + r.draftText);
    }

    @isTest
    static void docLinksFallBackToAllFedWhenSourcesUsedUnmatched() {
        // Model names an id NOT among the fed solutions -> still surface the fed solution's link.
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, verify the field API names.","sources_used":"nope-999",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status);
        System.assert(r.draftText.contains('https://example.atlassian.net/wiki/a01'),
            'An unmatched sources_used falls back to all fed links: ' + r.draftText);
    }

    // ---- #2 retry / error-vs-decline ----

    // Returns `emptyTimes` blank responses, then `good` thereafter; records the call count.
    private class FlakyClient implements SupportDraftingService.ModelClient {
        Integer emptyTimes;
        String good;
        public Integer calls = 0;
        FlakyClient(Integer emptyTimes, String good) { this.emptyTimes = emptyTimes; this.good = good; }
        public String generate(String modelName, String prompt) {
            calls++;
            return (calls <= emptyTimes) ? '' : good;
        }
    }

    @isTest
    static void transientEmptyThenSuccessRetries() {
        // First call comes back empty (transient), the retry succeeds -> a draft we'd otherwise have lost.
        FlakyClient stub = new FlakyClient(1, okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'A transient empty must be retried, not failed');
        System.assertEquals(2, stub.calls, 'One empty + one successful retry = 2 calls');
    }

    @isTest
    static void persistentEmptyExhaustsRetriesAsModelError() {
        // Every attempt is empty -> a genuine model error after exhausting retries (default 2 -> 3 calls).
        FlakyClient stub = new FlakyClient(99, okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_MODEL_ERROR', r.status);
        System.assertEquals(3, stub.calls, 'Initial attempt + 2 retries');
        System.assert(r.notes.contains('empty response'), 'Notes name the empty-response cause: ' + r.notes);
    }

    // ---- #4 retrieval-score floor ----

    @isTest
    static void belowScoreFloorDoesNotDraftAndSkipsModel() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.retrievalTopScore = 0.40; // below the configured floor (mdt Default = 0.50)

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status,
            'A sub-floor top score must not draft regardless of model confidence');
        System.assertEquals(false, stub.called, 'Floored cases must not spend a metered call');
        System.assert(r.notes.contains('floor'), 'Notes explain the floor: ' + r.notes);
    }

    @isTest
    static void atScoreFloorStillDrafts() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.retrievalTopScore = 0.50; // exactly at the configured floor (mdt Default = 0.50)

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status, 'At/above the floor a strong match still drafts');
        System.assert(stub.called);
    }

    // ---- #5 draft-trust gate ----

    @isTest
    static void draftTrustSourceIsGatedFromGeneration() {
        // A customer_safe doc whose trust tier is 'draft' (unreviewed WIP) must NOT be draft fuel.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].sourceType = 'draft'; // customer_safe but unreviewed

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_NO_MATCH', r.status,
            'An unreviewed draft-trust doc is not eligible to feed a customer-facing reply');
        System.assertEquals(false, stub.called, 'No reviewed customer-safe fuel -> no model call');
    }

    // ---- #3 grounding / faithfulness ----

    @isTest
    static void ungroundedDraftIsBlocked() {
        SupportDraftingService.testForceGrounding = true;
        // The model returns a fluent reply whose claims do NOT appear in the fed source -> block it.
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, navigate to the Billing Portal, open Subscription Settings, and toggle '
            + 'Automatic Renewal under the Payments tab to resolve this.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        // Source is about merge fields; the draft is about billing/renewal -> nothing traces.
        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status,
            'A draft whose claims do not trace to the cited source must be blocked');
        System.assertEquals(null, r.draftText, 'An ungrounded draft is never shown as fact');
        System.assert(r.notes.contains('grounding'), 'Notes explain the block: ' + r.notes);
        System.assert(stub.called, 'Grounding runs on a real generated draft');
    }

    @isTest
    static void groundedDraftPassesGrounding() {
        SupportDraftingService.testForceGrounding = true;
        // Draft paraphrases the fed source closely -> grounded -> DRAFTED.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'A draft that traces to the source passes grounding');
        System.assert(!r.notes.contains('grounding BLOCKED'));
    }

    @isTest
    static void scrubUngroundedUrlsDropsFabricatedLinks() {
        // A URL the model invented (not in any fed source) is stripped; a grounded source URL is kept.
        List<SupportDraftingService.SolutionContext> fed =
            new List<SupportDraftingService.SolutionContext>{ sol('a01', 'Doc', 'canned', 'Body text.') };
        String draft = 'Download it from https://help.sdocs.com/fake/install-link and see the reference '
            + 'at https://example.atlassian.net/wiki/a01.';
        SupportDraftingService.UrlScrubResult r = SupportDraftingService.scrubUngroundedUrls(draft, fed);
        System.assertEquals(1, r.removed, 'exactly the fabricated URL is removed');
        System.assert(!r.text.contains('help.sdocs.com/fake'), 'fabricated link gone: ' + r.text);
        System.assert(r.text.contains('example.atlassian.net/wiki/a01'), 'grounded link kept: ' + r.text);
    }

    // ---- Phase 1: LLM verification gate (second model call) ----

    // Returns the draft JSON on the first call and the verification JSON on the second (verify) call.
    private class TwoStepClient implements SupportDraftingService.ModelClient {
        String draftResp;
        String verifyResp;
        Boolean throwOnVerify = false;
        public Integer calls = 0;
        public String lastVerifyPrompt;
        public String lastVerifyModel;
        TwoStepClient(String d, String v) { this.draftResp = d; this.verifyResp = v; }
        public String generate(String modelName, String prompt) {
            calls++;
            if (calls == 1) { return draftResp; }
            lastVerifyPrompt = prompt;
            lastVerifyModel = modelName;
            if (throwOnVerify) { throw new CalloutException('verify callout failure'); }
            return verifyResp;
        }
    }

    private static String approveJson() {
        return '{"answers_specific_question": true, "all_claims_supported": true, '
            + '"fabricated_specifics": false, '
            + '"verdict": "approve", "reason": "answers the specific merge-field question from the source"}';
    }

    private static String declineJson() {
        return '{"answers_specific_question": false, "all_claims_supported": true, '
            + '"fabricated_specifics": false, '
            + '"verdict": "decline", "reason": "does not address the customer specific error"}';
    }

    @isTest
    static void verifyGateApprovesAndDrafts() {
        SupportDraftingService.testForceVerify = true;
        // Pin the verify model: the live CMDT sets its own judge model (currently GPT-4o), so the
        // assertion must not depend on the org value.
        SupportDraftingService.testForceVerifyModel = 'sfdc_ai__DefaultOpenAIGPT4OmniMini';
        TwoStepClient stub = new TwoStepClient(okJson(), approveJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'An approved draft is sent for review');
        System.assert(r.draftText.startsWith('Hi Dana'), 'Draft body returned: ' + r.draftText);
        System.assertEquals(2, stub.calls, 'One generation call + one verification call');
        System.assertEquals('sfdc_ai__DefaultOpenAIGPT4OmniMini', stub.lastVerifyModel,
            'The verification gate uses the configured verify model, not the drafting model');
        System.assert(stub.lastVerifyPrompt.contains('strict support-QA reviewer'),
            'The verifier prompt is the QA-reviewer prompt: ' + stub.lastVerifyPrompt);
        System.assert(stub.lastVerifyPrompt.contains('Merge fields blank'),
            'The verifier sees the case subject');
    }

    @isTest
    static void verifyGateDeclineRoutesToHuman() {
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), declineJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status,
            'A draft the verifier declines is never sent');
        System.assertEquals(null, r.draftText, 'No draft goes out on a verification decline');
        System.assert(r.notes.contains('verification gate DECLINED'), 'Notes mark the decline: ' + r.notes);
        System.assert(r.notes.contains('specific error'), 'The verifier reason is preserved: ' + r.notes);
    }

    @isTest
    static void verifyGateUnparseableFailsClosed() {
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), 'not json at all <<>>');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status,
            'An unparseable verification response fails closed (declines)');
        System.assertEquals(null, r.draftText);
        System.assert(r.notes.contains('unparseable'), 'Notes name the parse failure: ' + r.notes);
    }

    @isTest
    static void verifyGateMissingFieldsFailClosed() {
        // verdict says approve but the two required booleans are absent -> boolValue defaults false -> decline.
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), '{"verdict": "approve"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status,
            'A verdict without both criteria affirmed is not an approval');
    }

    @isTest
    static void verifyGateEmptyResponseFailsClosed() {
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), '');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status, 'An empty verification response declines');
        System.assert(r.notes.contains('empty'), 'Notes name the empty response: ' + r.notes);
    }

    @isTest
    static void verifyGateCalloutFailureFailsClosed() {
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), approveJson());
        stub.throwOnVerify = true;
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status,
            'A thrown verification callout fails closed - an unverifiable draft must not ship');
        System.assertEquals(null, r.draftText);
        System.assert(r.notes.contains('verification'), 'Notes explain the gate: ' + r.notes);
    }

    @isTest
    static void verifyGateOffPassesThroughWithoutSecondCall() {
        // Default under Test: the gate is off unless opted in -> no second call, draft proceeds.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'With the gate off the draft proceeds as before');
    }

    // ---- Phase 2: deterministic claim-level fabrication check ----

    @isTest
    static void claimCheckBlocksFabricatedSpecific() {
        SupportDraftingService.testForceClaimCheck = true;
        // Draft is otherwise grounded (reuses source vocab) so it clears the grounding check, but it asserts
        // a field API name that appears in NO cited source or the case -> the claim check must block it.
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, check that the field API names in your template match the object, then '
            + 'confirm the SSIC_Policy__c field is present.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status, 'A fabricated specific blocks the draft');
        System.assertEquals(null, r.draftText, 'A draft with an invented specific is never sent');
        System.assert(r.notes.contains('claim check'), 'Notes attribute the block to the claim check: ' + r.notes);
        System.assert(r.notes.contains('SSIC_Policy__c'), 'The unverifiable token is named: ' + r.notes);
    }

    @isTest
    static void claimCheckAllowsCustomerSuppliedSpecific() {
        SupportDraftingService.testForceClaimCheck = true;
        // The concrete token is in the CUSTOMER's own case text, not the source -> echoing it is not
        // fabrication, so the draft is allowed.
        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'My generated document shows blank merge fields; the SDOC__Has_Error__c '
            + 'checkbox is set on the record.';
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, please verify the field API names in your template match the object, then '
            + 'clear the SDOC__Has_Error__c field.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status,
            'A specific the customer themselves supplied is not a fabrication');
        System.assert(r.draftText.contains('SDOC__Has_Error__c'), 'The echoed token is kept: ' + r.draftText);
    }

    @isTest
    static void claimCheckAllowsSourceBackedSpecific() {
        SupportDraftingService.testForceClaimCheck = true;
        // The source itself carries the identifier -> reproducing it faithfully passes the claim check.
        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].body = 'Check that the field API names in the template match the object. If the '
            + 'GenerateDocumentInvocable action is used, confirm the mapping.';
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, verify the field API names in your template match the object, and check the '
            + 'GenerateDocumentInvocable action mapping.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status, 'A specific present in the cited source is verifiable');
    }

    // ---- demote-not-block gate mode (Draft_Gate_Mode__c = 'demote') ----

    @isTest
    static void demoteVerifyDeclineStillDrafts() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(), declineJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'In demote mode a declined draft still ships for review');
        System.assertEquals('LOW', r.confidence, 'A flagged draft is always LOW confidence');
        System.assertEquals('verify', r.gateFlags, 'The tripped gate is recorded: ' + r.gateFlags);
        System.assert(r.notes.startsWith('*** NEEDS REVIEW'), 'Warning block tops the notes: ' + r.notes);
        System.assert(r.notes.contains('verification declined'), 'The verifier verdict is surfaced: ' + r.notes);
        System.assert(r.draftText.startsWith('Hi Dana'), 'The draft text is preserved');
    }

    @isTest
    static void demoteClaimFailJudgeApprovesStillDrafts() {
        // Deterministic claim hit + the LLM judge overrules it (all_claims_supported=true) ->
        // the hit is treated as extractor noise: draft ships flagged for review.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceClaimCheck = true;
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(
            '{"draft":"Hi Dana, check that the field API names in your template match the object, then '
            + 'confirm the SSIC_Policy__c field is present.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}', approveJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'A judge-overruled claim hit demotes instead of blocking');
        System.assertEquals('LOW', r.confidence);
        System.assertEquals('claims', r.gateFlags);
        System.assert(r.notes.contains('claim check'), 'Warning attributes the flag: ' + r.notes);
        System.assert(r.notes.contains('SSIC_Policy__c'), 'The unverifiable token is named: ' + r.notes);
    }

    @isTest
    static void demoteClaimFailWithoutJudgeBlocks() {
        // Deterministic fabrication evidence with NO verify judge to adjudicate it fails closed,
        // even in demote mode: facts outside the documents are never shipped unreviewed.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceClaimCheck = true;
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, check that the field API names in your template match the object, then '
            + 'confirm the SSIC_Policy__c field is present.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status,
            'An unadjudicated claim hit blocks even in demote mode');
        System.assertEquals(null, r.draftText, 'No fabricated draft ships');
        System.assert(r.notes.contains('SSIC_Policy__c'), 'The unverifiable token is named: ' + r.notes);
    }

    @isTest
    static void demoteCorroboratedFabricationBlocks() {
        // BOTH detectors agree — deterministic claim hit AND the judge confirms fabrication ->
        // never demotable, even in demote mode.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceClaimCheck = true;
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(
            '{"draft":"Hi Dana, check that the field API names in your template match the object, then '
            + 'confirm the SSIC_Policy__c field is present.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}',
            '{"answers_specific_question": true, "all_claims_supported": false, '
            + '"fabricated_specifics": true, '
            + '"verdict": "decline", "reason": "SSIC_Policy__c appears in no source"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status,
            'Corroborated fabrication blocks even in demote mode');
        System.assertEquals(null, r.draftText, 'No fabricated draft ships');
        System.assert(r.notes.contains('fabricated specifics'), 'Notes name the fabrication: ' + r.notes);
    }

    @isTest
    static void demoteJudgeOnlyFabricationSuspicionDemotes() {
        // The judge alone suspects invented specifics (no deterministic corroboration) -> a single
        // sampled opinion demotes with a loud warning instead of blocking.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(),
            '{"answers_specific_question": true, "all_claims_supported": false, '
            + '"fabricated_specifics": true, '
            + '"verdict": "decline", "reason": "the draft asserts a reset period not present in any source"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status,
            'Judge-only fabrication suspicion demotes instead of blocking');
        System.assertEquals('LOW', r.confidence);
        System.assertEquals('verify', r.gateFlags);
        System.assert(r.notes.contains('INVENTED specifics'), 'The suspicion warning is loud: ' + r.notes);
        System.assert(r.notes.contains('reset period'), 'The judge reason is preserved: ' + r.notes);
    }

    @isTest
    static void demoteVerifyUnsupportedButNotFabricatedDemotes() {
        // Strict "not fully supported" WITHOUT invented concrete facts is elaboration, not
        // fabrication -> demotable: the draft ships flagged for the reviewer.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(okJson(),
            '{"answers_specific_question": true, "all_claims_supported": false, '
            + '"fabricated_specifics": false, '
            + '"verdict": "decline", "reason": "advice goes beyond the sources but invents no facts"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status,
            'Unsupported-but-not-fabricated declines demote instead of blocking');
        System.assertEquals('LOW', r.confidence);
        System.assertEquals('verify', r.gateFlags);
        System.assert(r.notes.contains('verification declined'), 'The decline is surfaced: ' + r.notes);
    }

    @isTest
    static void demoteClaimFailJudgeUnparseableBlocks() {
        // Deterministic claim hit + the judge response cannot be parsed -> the hit stands
        // unadjudicated -> fail closed even in demote mode.
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceClaimCheck = true;
        SupportDraftingService.testForceVerify = true;
        TwoStepClient stub = new TwoStepClient(
            '{"draft":"Hi Dana, check that the field API names in your template match the object, then '
            + 'confirm the SSIC_Policy__c field is present.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}', 'not json at all <<>>');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status,
            'A claim hit with an unparseable judge response blocks even in demote mode');
        System.assertEquals(null, r.draftText);
    }

    @isTest
    static void demoteGroundingBlockIsTerminal() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceGrounding = true;
        // Same ungrounded reply as ungroundedDraftIsBlocked — nothing traces to the fed source.
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, navigate to the Billing Portal, open Subscription Settings, and toggle '
            + 'Automatic Renewal under the Payments tab to resolve this.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNGROUNDED', r.status,
            'A grounding hard-fail blocks even in demote mode — fabrication is never demotable');
        System.assertEquals(null, r.draftText, 'No ungrounded draft ships');
        System.assert(r.notes.contains('grounding BLOCKED'), 'Notes mark the block: ' + r.notes);
    }

    @isTest
    static void demoteCleanDraftIsUnflagged() {
        SupportDraftingService.testForceGateMode = 'demote';
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status);
        System.assertEquals('HIGH', r.confidence, 'A clean draft keeps its earned confidence in demote mode');
        System.assertEquals(null, r.gateFlags, 'No gate tripped -> no flags');
        System.assert(!r.notes.contains('NEEDS REVIEW'), 'No warning block on a clean draft: ' + r.notes);
    }

    @isTest
    static void extractConcreteTokensFindsSpecificsIgnoresProse() {
        String draft = 'Set `format-number` and the SSIC_Policy__c field, use autoopen=\'newtab\', the '
            + 'GenerateDocumentInvocable action, and version v6.1.10. This plain sentence has no specifics.';
        List<String> toks = SupportDraftingService.extractConcreteTokens(draft);
        String joined = String.join(toks, '|').toLowerCase();
        System.assert(joined.contains('ssic_policy__c'), 'API name captured: ' + joined);
        System.assert(joined.contains('generatedocumentinvocable'), 'CamelCase captured: ' + joined);
        System.assert(joined.contains('format-number'), 'Back-ticked code captured: ' + joined);
        System.assert(joined.contains('newtab'), 'Attribute captured: ' + joined);
        System.assert(joined.contains('6.1.10'), 'Version captured: ' + joined);
        System.assert(!joined.contains('sentence'), 'Plain prose is not captured as a specific: ' + joined);
    }

    @isTest
    static void extractConcreteTokensSkipsMarkupAndProseSpans() {
        // Measured claim-check false positives (2026-07-21 eval): a composed HTML/CSS illustration
        // and prose captured between two adjacent code spans (backtick pairing drift).
        String draft = 'Size it with `<img style="width:100px; height:auto;">` in the template. '
            + 'Use `.table1col2` for that column` and other classes cover the rest of the table. `'
            + 'Also set the SSIC_Policy__c field.';
        List<String> toks = SupportDraftingService.extractConcreteTokens(draft);
        String joined = String.join(toks, '|').toLowerCase();
        System.assert(!joined.contains('img style'), 'Markup example span is not a claim token: ' + joined);
        System.assert(!joined.contains('other classes'), 'Prose drift span is not a claim token: ' + joined);
        System.assert(joined.contains('.table1col2'), 'Short code span still verified: ' + joined);
        System.assert(joined.contains('ssic_policy__c'), 'Concrete sub-tokens still verified: ' + joined);
    }

    // ---- structural-unanswerability pre-decline ----

    @isTest
    static void structuralScreenshotOnlyDeclinesBeforeModelCall() {
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseSubject = 'Problem generating my document';
        in1.caseDescription = 'It fails every time. Screenshot attached so you can see what happens.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status,
            'A screenshot-only case declines: the decisive error is unreadable');
        System.assertEquals(false, stub.called, 'Declined before the metered call');
        System.assert(r.notes.contains('[structural: screenshot_only]'),
            'The structural reason is machine-taggable: ' + r.notes);
    }

    @isTest
    static void structuralScreenshotSparedByConcreteErrorText() {
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'See attached screenshot. The error says "Attempt to de-reference a '
            + 'null object" when my document generates with blank merge fields.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status,
            'Concrete error text in the case makes it answerable despite the screenshot mention');
    }

    @isTest
    static void structuralRegressionDeclines() {
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseSubject = 'Documents not generating';
        in1.caseDescription = 'Document generation worked fine yesterday but today nothing '
            + 'generates at all. Nothing changed on our side.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status,
            'A worked-yesterday regression with no error text declines to a human');
        System.assertEquals(false, stub.called, 'Declined before the metered call');
        System.assert(r.notes.contains('[structural: regression]'), 'Tagged as regression: ' + r.notes);
    }

    @isTest
    static void structuralRegressionSparedByReleaseMention() {
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'My merge fields stopped working after the latest Salesforce release; '
            + 'the generated document shows blank merge fields.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status,
            'A release-mention regression maps to release-compat corpus topics and may draft');
    }

    @isTest
    static void structuralPhoneNumberIsNotSubstance() {
        // Smoke case 00034112: a dotted phone number in the signature must not read as a version.
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseSubject = 'Page Break Issue';
        in1.caseDescription = 'I am getting a strange issue (see the attached). Can you help me?\n'
            + 'M: 231.346.8780';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('NO_DRAFT_LOW_CONFIDENCE', r.status,
            'A dotted phone number is not concrete substance');
        System.assert(r.notes.contains('[structural: screenshot_only]'), r.notes);
    }

    @isTest
    static void structuralSignatureLogoDoesNotTrigger() {
        // Smoke case 00034164: an Outlook signature's embedded [cid:...] logo is not a screenshot
        // reference; a purely textual question must not structurally decline.
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'My generated document shows blank merge fields - what setting '
            + 'controls this?\n\nJane Doe | Salesforce Administrator\n'
            + '[cid:image001.jpg@01DCE38D.590C8980]\n[cid:image002.png@01DCE38D.590C8980]';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status,
            'Signature cid logos alone must not trigger the screenshot decline');
    }

    @isTest
    static void structuralSparedByArticulatedQuestion() {
        // Smoke case 00033976: prose that states the substance ("let me know how/why X happened")
        // makes the case answerable even though screenshots are attached.
        SupportDraftingService.testForceStructuralDecline = true;
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'The confirmation email was sent to another user which is not '
            + 'configured, please let me know how/why this happened (screenshots attached). '
            + 'My generated document shows blank merge fields.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status,
            'An articulated how/why question is substance; the screenshot mention does not decline it');
    }

    @isTest
    static void structuralGateOffByDefaultDrafts() {
        // No opt-in -> the gate is inert, matching the code default (the Default record enables it).
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.caseDescription = 'It fails every time. Screenshot attached so you can see what happens.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status, 'Gate off -> unchanged behavior');
    }

    // ---- persona scrub: we ARE S-Docs Support ----

    @isTest
    static void personaReferralRewrittenInDraft() {
        StubClient stub = new StubClient(
            '{"draft":"Hi Dana, you have reached your document limit. Please contact S-Docs Support '
            + 'directly to have the limit increased.","sources_used":"a01",'
            + '"agent_notes":"ok","confidence":"HIGH"}');
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftInput in1 = baseInput();
        in1.solutions[0].body = 'When you have reached your document limit, contact S-Docs Support '
            + 'directly to have the limit increased.';

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(in1);

        System.assertEquals('DRAFTED', r.status);
        System.assert(!r.draftText.toLowerCase().contains('contact s-docs'),
            'The vendor referral is rewritten - we are S-Docs Support: ' + r.draftText);
        System.assert(r.draftText.contains('let us know'), 'Referral becomes an offer we fulfil: ' + r.draftText);
        System.assert(r.notes.contains('referral(s) rewritten'), 'The rewrite is audited: ' + r.notes);
    }

    // ---- verify second vote (demote mode) ----

    // Returns queued responses in order; optionally throws on the nth call.
    private class SeqClient implements SupportDraftingService.ModelClient {
        List<String> responses;
        Integer throwOnCall = -1;
        public Integer calls = 0;
        SeqClient(List<String> rs) { this.responses = rs; }
        public String generate(String modelName, String prompt) {
            calls++;
            if (calls == throwOnCall) { throw new CalloutException('simulated callout failure'); }
            return responses[Math.min(calls, responses.size()) - 1];
        }
    }

    @isTest
    static void secondVoteDoubleDeclineBlocks() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        SupportDraftingService.testForceVerifySecondVote = true;
        SeqClient stub = new SeqClient(new List<String>{ okJson(), declineJson(), declineJson() });
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status,
            'Two independent affirmative declines block instead of demoting');
        System.assertEquals(null, r.draftText, 'A twice-declined draft never ships');
        System.assertEquals(3, stub.calls, 'One generation + two verification samples');
        System.assert(r.notes.contains('DECLINED by both votes'), 'Notes mark the double decline: ' + r.notes);
    }

    @isTest
    static void secondVoteSplitDemotes() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        SupportDraftingService.testForceVerifySecondVote = true;
        SeqClient stub = new SeqClient(new List<String>{ okJson(), declineJson(), approveJson() });
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status, 'A split vote demotes for review, as one decline did before');
        System.assertEquals('verify', r.gateFlags);
        System.assertEquals('LOW', r.confidence);
        System.assertEquals(3, stub.calls, 'The second sample was drawn');
    }

    @isTest
    static void secondVoteUnreachableFallsBackToDemote() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        SupportDraftingService.testForceVerifySecondVote = true;
        SeqClient stub = new SeqClient(new List<String>{ okJson(), declineJson(), approveJson() });
        stub.throwOnCall = 3;
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status,
            'Blocking needs two affirmative declines; an unreachable second sample demotes');
        System.assertEquals('verify', r.gateFlags);
    }

    @isTest
    static void secondVoteGarbledFallsBackToDemote() {
        SupportDraftingService.testForceGateMode = 'demote';
        SupportDraftingService.testForceVerify = true;
        SupportDraftingService.testForceVerifySecondVote = true;
        SeqClient stub = new SeqClient(new List<String>{ okJson(), declineJson(), 'not json <<>>' });
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('DRAFTED', r.status,
            'An unparseable second sample is not an affirmative decline -> demote');
        System.assertEquals('verify', r.gateFlags);
    }

    @isTest
    static void secondVoteIgnoredInBlockMode() {
        // Block mode is already fail-closed on the first decline; the second sample is a
        // demote-mode refinement and must not spend an extra call here.
        SupportDraftingService.testForceVerify = true;
        SupportDraftingService.testForceVerifySecondVote = true;
        SeqClient stub = new SeqClient(new List<String>{ okJson(), declineJson(), approveJson() });
        SupportDraftingService.client = stub;

        SupportDraftingService.DraftResult r = SupportDraftingService.draft(baseInput());

        System.assertEquals('NO_DRAFT_UNVERIFIED', r.status);
        System.assertEquals(2, stub.calls, 'No second sample in block mode');
    }

    @isTest
    static void extractConcreteTokensKeepsCodeLikeSpansStrict() {
        // A fabricated-syntax span (00034021: invented SOQL AS-aliasing) has code signals
        // (ALL-CAPS keywords, CamelCase) and must remain a whole-span claim token.
        String draft = 'Query it via `SELECT Name, StageName AS Stage FROM Opportunity` in the template.';
        List<String> toks = SupportDraftingService.extractConcreteTokens(draft);
        String joined = String.join(toks, '|');
        System.assert(joined.contains('SELECT Name, StageName AS Stage FROM Opportunity'),
            'Code-like span keeps strict whole-span matching: ' + joined);
    }

}
