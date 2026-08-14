/**
 * Single Flow entry point for the Origin=Email drafting path: retrieve candidates, route an
 * escalate-only top match before paying for generation, and make the one gated draft() call.
 * Stateless; never throws to the Flow — every failure maps to a NO_DRAFT_* / ESCALATE status.
 */
public with sharing class SupportDraftOrchestrator {

    @TestVisible private static final String STATUS_ESCALATE = SupportDraftVocab.STATUS_ESCALATE;

    @InvocableMethod(label='Orchestrate Support Draft'
        description='Single entry point for the email drafting path: retrieves candidate solutions, routes escalate-only matches, and makes the one gated LLM draft call. Returns a routed outcome for the Flow to stamp onto the Case.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(orchestrate(req));
        }
        return results;
    }

    public static Result orchestrate(Request req) {
        Result r = new Result();
        if (req == null) {
            r.status = SupportDraftVocab.NO_DRAFT_NO_MATCH;
            r.notes = 'No request provided; routed to a human.';
            return r;
        }

        // Excluded categories (junk/billing per CaseIntakeClassifier, or a Flow-set flag) skip
        // retrieval entirely — no callouts are spent on a case that must not be auto-drafted.
        // draft() re-checks the same flag as defense in depth; the wording here mirrors its stamp.
        if (req.excluded == true) {
            r.status = SupportDraftVocab.NO_DRAFT_EXCLUDED;
            r.confidence = 'NONE';
            r.notes = 'Excluded category: ' + (String.isBlank(req.excludedReason)
                ? 'flagged do-not-auto-draft' : req.excludedReason) + '. Routed to a human.';
            return r;
        }

        SupportRetrievalService.RetrievalResult retr =
            SupportRetrievalService.retrieveResilient(buildRetrievalInput(req));
        r.confidence = retr.confidence;
        // Set before the escalate-only early return so every routed outcome carries the score.
        r.retrievalTopScore = (retr.topScore == null) ? null : retr.topScore.doubleValue();

        // Distillation audit: the distilled query is sampled, so two identical emails can record
        // different scores — this note keeps those divergences self-explaining. distillOutcome is
        // the same fact as a typed field, so consumers (the eval job) never parse the prose.
        String distillNote = '';
        r.distillOutcome = 'no';
        if (String.isNotBlank(retr.distilledQuery)) {
            r.distillOutcome = retr.distilled ? 'won' : 'tried';
            distillNote = retr.distilled
                ? 'Retrieval used the LLM-distilled query "' + retr.distilledQuery + '" (it decisively beat the raw case text).'
                : 'An LLM-distilled retrieval query ("' + retr.distilledQuery + '") was tried but did not decisively beat the raw case text; the original pass was kept.';
        }

        // An escalate_only top match flips to escalation BEFORE generation is paid for.
        if (!retr.candidates.isEmpty()
                && 'escalate_only'.equalsIgnoreCase(retr.candidates[0].visibility)) {
            r.status = STATUS_ESCALATE;
            r.notes = withDistillNote(
                'Top knowledge-store match is escalate-only; routed to escalation. No draft generated.',
                distillNote);
            return r;
        }

        SupportDraftingService.DraftInput din = new SupportDraftingService.DraftInput();
        din.caseSubject = req.subject;
        din.caseDescription = req.description;
        din.product = req.product;
        din.customerName = req.customerName;
        din.excluded = (req.excluded == true);
        din.excludedReason = req.excludedReason;
        din.retrievalConfidence = retr.confidence;
        din.retrievalTopScore = (retr.topScore == null) ? null : retr.topScore.doubleValue();
        din.solutions = mapCandidates(retr.candidates);

        SupportDraftingService.DraftResult dr = SupportDraftingService.draft(din);

        r.status = dr.status;
        r.draftText = dr.draftText;
        r.confidence = dr.confidence; // draft() clamps to retrieval confidence
        r.notes = withDistillNote(dr.notes, distillNote);
        r.modelName = dr.modelName;
        r.gateFlags = dr.gateFlags;
        r.sourceIds = dr.sourceIds;
        r.sourceIdsCsv = (dr.sourceIds == null) ? null : String.join(dr.sourceIds, ', ');
        return r;
    }

    private static String withDistillNote(String notes, String distillNote) {
        if (String.isBlank(distillNote)) { return notes; }
        return String.isBlank(notes) ? distillNote : notes + '\n' + distillNote;
    }

    @TestVisible
    private static SupportRetrievalService.RetrievalInput buildRetrievalInput(Request req) {
        SupportRetrievalService.RetrievalInput inp = new SupportRetrievalService.RetrievalInput();
        String subject = (req.subject == null) ? '' : req.subject;
        String description = (req.description == null) ? '' : req.description;
        inp.searchText = (subject + '\n' + description).trim();
        inp.product = String.isBlank(req.product) ? null : req.product.trim();
        return inp;
    }

    @TestVisible
    private static List<SupportDraftingService.SolutionContext> mapCandidates(
            List<SupportRetrievalService.Candidate> candidates) {
        List<SupportDraftingService.SolutionContext> out =
            new List<SupportDraftingService.SolutionContext>();
        if (candidates == null || candidates.isEmpty()) { return out; }

        // A Candidate carries only a 300-char snippet — too little to draft from (the model would decline).
        // Fetch the full Body__c by Id here and feed that to generation; fall back to the snippet.
        Set<Id> ids = new Set<Id>();
        for (SupportRetrievalService.Candidate c : candidates) {
            if (c.solutionId != null) { ids.add(c.solutionId); }
        }
        Map<Id, Support_Solution__c> bodyById = new Map<Id, Support_Solution__c>(
            [SELECT Id, Body__c FROM Support_Solution__c WHERE Id IN :ids]);

        for (SupportRetrievalService.Candidate c : candidates) {
            SupportDraftingService.SolutionContext s = new SupportDraftingService.SolutionContext();
            s.solutionId = (c.solutionId == null) ? null : String.valueOf(c.solutionId);
            s.name = c.name;
            s.sourceType = c.sourceType;
            s.visibility = c.visibility;
            s.solutionType = c.solutionType;
            s.product = c.product;
            s.hasRequiredDisclaimer = c.hasRequiredDisclaimer;
            s.relevanceScore = (c.score == null) ? null : c.score.doubleValue();
            s.url = c.url;
            Support_Solution__c full = (c.solutionId == null) ? null : bodyById.get(c.solutionId);
            s.body = (full != null && String.isNotBlank(full.Body__c)) ? full.Body__c : c.snippet;
            out.add(s);
        }
        return out;
    }

    public class Request {
        @InvocableVariable(required=true label='Case Subject') public String subject;
        @InvocableVariable(label='Case Description') public String description;
        @InvocableVariable(label='Product (Product_List__c; blank = search both)') public String product;
        @InvocableVariable(label='Customer Name') public String customerName;
        @InvocableVariable(label='Excluded Category?') public Boolean excluded;
        @InvocableVariable(label='Excluded Reason') public String excludedReason;
    }

    public class Result {
        // DRAFTED | ESCALATE | NO_DRAFT_NO_MATCH | NO_DRAFT_EXCLUDED | NO_DRAFT_LOW_CONFIDENCE |
        // NO_DRAFT_UNGROUNDED | NO_DRAFT_MODEL_ERROR
        @InvocableVariable public String status;
        @InvocableVariable public String draftText;
        @InvocableVariable public String confidence;       // HIGH | MEDIUM | LOW | NONE
        @InvocableVariable public String notes;
        @InvocableVariable public String modelName;
        @InvocableVariable public List<String> sourceIds;  // solutions actually fed to the model
        @InvocableVariable public String sourceIdsCsv;     // sourceIds joined, for stamping a text field
        @InvocableVariable public Double retrievalTopScore; // calibrated retrieval top score [0,1]; audit only
        @InvocableVariable public String distillOutcome;   // 'won' | 'tried' | 'no' — typed distill audit
        @InvocableVariable public String gateFlags;        // csv of demoted gates ('grounding,claims,verify'); null = clean
    }
}
