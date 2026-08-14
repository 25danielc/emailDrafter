/**
 * Dry-run batch evaluation of the draft pipeline over a fixed cohort of existing Cases.
 * Chained Queueable (embedder pattern): each execution runs CHUNK_SIZE cases through
 * SupportDraftOrchestrator.orchestrate() with the SAME three-field mapping the production flow
 * uses (Subject / Description / Product_List__c), accumulates one Row per case across
 * re-enqueues, and on completion writes a single CSV report to a ContentVersion titled
 * 'Draft Eval <runLabel>'. Zero Case writes, no draft EmailMessages — the orchestrator is
 * stateless by design (D26) and this job's only DML is the final report insert.
 *
 * Kick off via scripts/apex/run_draft_eval.apex; fetch via scripts/apex/fetch_draft_eval.apex.
 */
public with sharing class DraftEvalBatchJob implements Queueable, Database.AllowsCallouts {

    // Worst case per case: ~6 callouts (embed + distill re-pass + generation retries) and up to
    // 6 SOSL (tier1 + tier2 + error-string channel, twice with the distill re-pass). 3 cases/link
    // keeps the SOSL worst case at 18 (< 20/transaction) so the error-string channel always runs;
    // callouts stay far under the 100/120s limits.
    @TestVisible private static Integer CHUNK_SIZE = 3;
    private static final Integer MAX_DEPTH = 40;          // 40 * 3 = 120-case backstop
    private static final Integer SUBJECT_MAX = 80;
    private static final Integer NOTES_MAX = 300;
    private static final Integer DRAFT_EXCERPT_MAX = 200;
    // The companion detail JSON carries the full draft (the CSV keeps only a 200-char excerpt) so
    // the post-run reviewer agents can judge good-draft vs false-positive. Capped so a runaway
    // generation can't bloat the serialized Queueable state carried across re-enqueues.
    private static final Integer DRAFT_FULL_MAX = 4000;
    // ISO-8601 UTC so the created-date column sorts and parses cleanly in any spreadsheet.
    private static final String ISO_UTC = 'yyyy-MM-dd\'T\'HH:mm:ss\'Z\'';

    /** Seam so tests can substitute the pipeline call (orchestrate() itself never throws by design). */
    public interface OrchestrateFn {
        SupportDraftOrchestrator.Result call(SupportDraftOrchestrator.Request req);
    }
    private class RealOrchestrate implements OrchestrateFn {
        public SupportDraftOrchestrator.Result call(SupportDraftOrchestrator.Request req) {
            return SupportDraftOrchestrator.orchestrate(req);
        }
    }
    @TestVisible private static OrchestrateFn fn = new RealOrchestrate();

    /** One result row per case; small on purpose — full draft text is never carried through the chain. */
    public class Row {
        public String caseId;
        public String caseNumber;
        public String createdDate;    // Case.CreatedDate, ISO-8601 UTC
        public String product;
        public String subject;        // truncated to SUBJECT_MAX
        public String intake;         // JUNK | BILLING | LEGIT — CaseIntakeClassifier verdict;
                                      // the legit-drafted-rate denominator is intake == 'LEGIT'
        public String status;         // orchestrator status, or 'ERROR' when the call threw
        public String confidence;     // HIGH | MEDIUM | LOW | NONE
        public Double topScore;       // Result.retrievalTopScore (null when retrieval never scored)
        public String distill;        // 'won' | 'tried' | 'no' — parsed from the stable distill notes
        public String gateFlags;      // demoted verification gates csv; null/blank = clean draft
        public Integer sourceCount;
        public String sourceIdsCsv;   // the Support_Solution__c Ids fed to the model (detail JSON)
        public Integer draftChars;
        public String draftExcerpt;   // first DRAFT_EXCERPT_MAX chars (CSV)
        public String draftFull;      // first DRAFT_FULL_MAX chars (detail JSON, for reviewer labeling)
        public String notesExcerpt;   // first NOTES_MAX chars
        public Integer elapsedMs;
        public String errorDetail;
    }

    /** DRAFTED is the only status that emits a reviewable draft; every other outcome is "not generated". */
    @TestVisible
    private static String generatedFlag(String status) {
        return SupportDraftVocab.STATUS_DRAFTED.equals(status) ? 'yes' : 'no';
    }

    private final List<Id> caseIds;   // full ordered cohort, fixed at kickoff
    private final Integer cursor;     // index of the next unprocessed case
    private final Integer depth;
    // Accumulated across re-enqueues (Queueable state is serialized with the job).
    @TestVisible private final List<Row> rows;
    private final String runLabel;

    public DraftEvalBatchJob(List<Id> caseIds, String runLabel) {
        this(caseIds, 0, 0, new List<Row>(), runLabel);
    }

    @TestVisible
    private DraftEvalBatchJob(List<Id> caseIds, Integer cursor, Integer depth, List<Row> rows,
                              String runLabel) {
        this.caseIds = (caseIds == null) ? new List<Id>() : caseIds;
        this.cursor = cursor;
        this.depth = depth;
        this.rows = (rows == null) ? new List<Row>() : rows;
        this.runLabel = String.isBlank(runLabel) ? 'eval' : runLabel;
    }

    public void execute(QueueableContext ctx) {
        if (depth >= MAX_DEPTH) {
            // Bail with what we have rather than losing the accumulated rows.
            saveReport(true);
            System.debug(LoggingLevel.ERROR, 'DraftEvalBatchJob hit MAX_DEPTH at cursor ' + cursor
                + '; wrote PARTIAL report.');
            return;
        }

        Integer endIdx = Math.min(cursor + CHUNK_SIZE, caseIds.size());
        List<Id> slice = new List<Id>();
        for (Integer i = cursor; i < endIdx; i++) { slice.add(caseIds[i]); }

        Map<Id, Case> byId = new Map<Id, Case>([
            SELECT Id, CaseNumber, Subject, Description, Product_List__c, SuppliedEmail, CreatedDate
            FROM Case WHERE Id IN :slice
        ]);

        for (Id cid : slice) {
            rows.add(evalOne(cid, byId.get(cid)));
        }

        if (endIdx < caseIds.size()) {
            if (!Test.isRunningTest()) {
                System.enqueueJob(new DraftEvalBatchJob(caseIds, endIdx, depth + 1, rows, runLabel));
            }
        } else {
            saveReport(false);
            System.debug(LoggingLevel.ERROR, 'DraftEvalBatchJob complete: ' + rows.size()
                + ' rows -> ContentVersion "Draft Eval ' + runLabel + '". ' + summary());
        }
    }

    private Row evalOne(Id cid, Case c) {
        Row row = new Row();
        row.caseId = String.valueOf(cid);
        if (c == null) {
            row.status = 'ERROR';
            row.errorDetail = 'Case not found (deleted or inaccessible)';
            return row;
        }
        row.caseNumber = c.CaseNumber;
        row.createdDate = (c.CreatedDate == null) ? null : c.CreatedDate.formatGmt(ISO_UTC);
        row.product = c.Product_List__c;
        row.subject = truncate(c.Subject, SUBJECT_MAX);

        // Flow parity: production classifies intake before the orchestrator, so the eval must too —
        // junk never reaches the orchestrator (no callouts), billing goes in pre-excluded.
        CaseIntakeClassifier.Verdict intake =
            CaseIntakeClassifier.classify(c.Subject, c.Description, c.SuppliedEmail);
        row.intake = intake.category;
        if (CaseIntakeClassifier.CATEGORY_JUNK.equals(intake.category)) {
            row.status = SupportDraftVocab.NO_DRAFT_EXCLUDED;
            row.confidence = 'NONE';
            row.distill = 'no';
            row.sourceCount = 0;
            row.draftChars = 0;
            row.notesExcerpt = truncate(intake.reason, NOTES_MAX);
            row.elapsedMs = 0;
            return row;
        }

        // Exact production-flow mapping: subject/description/product (plus the intake exclusion
        // AutomatedEmailDrafting now sets), so results mirror what the live path would have produced.
        SupportDraftOrchestrator.Request req = new SupportDraftOrchestrator.Request();
        req.subject = c.Subject;
        req.description = c.Description;
        req.product = c.Product_List__c;
        if (CaseIntakeClassifier.CATEGORY_BILLING.equals(intake.category)) {
            req.excluded = true;
            req.excludedReason = intake.reason;
        }

        Long t0 = System.currentTimeMillis();
        try {
            SupportDraftOrchestrator.Result r = fn.call(req);
            row.status = r.status;
            row.confidence = r.confidence;
            row.topScore = r.retrievalTopScore;
            row.distill = (r.distillOutcome != null) ? r.distillOutcome : classifyDistill(r.notes);
            row.gateFlags = r.gateFlags;
            row.sourceCount = (r.sourceIds == null) ? 0 : r.sourceIds.size();
            row.sourceIdsCsv = (r.sourceIdsCsv != null) ? r.sourceIdsCsv
                : (r.sourceIds == null ? null : String.join(r.sourceIds, ';'));
            row.draftChars = (r.draftText == null) ? 0 : r.draftText.length();
            row.draftExcerpt = truncate(r.draftText, DRAFT_EXCERPT_MAX);
            row.draftFull = truncate(r.draftText, DRAFT_FULL_MAX);
            row.notesExcerpt = truncate(r.notes, NOTES_MAX);
        } catch (Exception e) {
            row.status = 'ERROR';
            row.errorDetail = e.getTypeName() + ': ' + truncate(e.getMessage(), NOTES_MAX);
        }
        row.elapsedMs = (Integer) (System.currentTimeMillis() - t0);
        return row;
    }

    /** Prose fallback for results that predate Result.distillOutcome (the typed field is preferred). */
    @TestVisible
    private static String classifyDistill(String notes) {
        if (notes == null) { return 'no'; }
        if (notes.contains('Retrieval used the LLM-distilled query')) { return 'won'; }
        if (notes.contains('was tried but did not decisively beat')) { return 'tried'; }
        return 'no';
    }

    private void saveReport(Boolean partial) {
        List<ContentVersion> cvs = new List<ContentVersion>();

        ContentVersion csvCv = new ContentVersion();
        csvCv.Title = 'Draft Eval ' + runLabel + (partial ? ' PARTIAL' : '');
        csvCv.PathOnClient = 'draft-eval-' + runLabel + (partial ? '-partial' : '') + '.csv';
        csvCv.VersionData = Blob.valueOf(toCsv(rows, runLabel, caseIds.size()));
        cvs.add(csvCv);

        // Companion full-text JSON: the untruncated case + draft + notes the reviewer agents ground
        // their should-have-drafted labels on (the CSV keeps only excerpts for human reading).
        ContentVersion jsonCv = new ContentVersion();
        jsonCv.Title = 'Draft Eval Detail ' + runLabel + (partial ? ' PARTIAL' : '');
        jsonCv.PathOnClient = 'draft-eval-detail-' + runLabel + (partial ? '-partial' : '') + '.json';
        jsonCv.VersionData = Blob.valueOf(buildDetailJson());
        cvs.add(jsonCv);

        insert cvs;
    }

    /**
     * Full-text per-case detail for reviewer labeling. The chain carries only capped draft text, so
     * the long, untruncated Subject/Description are re-queried here (one SOQL at report time) rather
     * than serialized across every re-enqueue.
     */
    private String buildDetailJson() {
        Map<Id, Case> byId = new Map<Id, Case>([
            SELECT Id, CaseNumber, Subject, Description FROM Case WHERE Id IN :caseIds
        ]);
        List<Object> records = new List<Object>();
        for (Row r : rows) {
            Case c = (r.caseId == null) ? null : byId.get((Id) r.caseId);
            records.add(new Map<String, Object>{
                'caseNumber'  => r.caseNumber,
                'caseId'      => r.caseId,
                'createdDate' => r.createdDate,
                'product'     => r.product,
                'intake'      => r.intake,
                'generated'   => generatedFlag(r.status),
                'status'      => r.status,
                'confidence'  => r.confidence,
                'topScore'    => r.topScore,
                'gateFlags'   => r.gateFlags,
                'sourceCount' => r.sourceCount,
                'sourceIds'   => r.sourceIdsCsv,
                'subject'     => (c == null) ? r.subject : c.Subject,
                'description' => (c == null) ? null : c.Description,
                'draft'       => r.draftFull,
                'notes'       => r.notesExcerpt,
                'errorDetail' => r.errorDetail
            });
        }
        return JSON.serializePretty(records);
    }

    private String summary() {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Row r : rows) {
            Integer n = counts.get(r.status);
            counts.put(r.status, (n == null ? 0 : n) + 1);
        }
        return 'Status counts: ' + JSON.serialize(counts);
    }

    @TestVisible
    private static String toCsv(List<Row> rows, String runLabel, Integer cohortSize) {
        List<String> lines = new List<String>();
        lines.add('# run=' + runLabel + ' cohort=' + cohortSize + ' rows=' + rows.size()
            + ' chunk=' + CHUNK_SIZE);
        // Column order mirrors the requested eval spec: (1) generated, (2) confidence, (3) metrics,
        // (4) createdDate, (5) type-of-case, (6) reviewer verdict (filled post-run), (7) other.
        lines.add('generated,confidence,topScore,sourceCount,draftChars,elapsedMs,distill,gateFlags,'
            + 'createdDate,product,intake,should_have_drafted,label,review_reason,'
            + 'caseNumber,caseId,subject,status,draftExcerpt,notesExcerpt,errorDetail');
        for (Row r : rows) {
            lines.add(String.join(new List<String>{
                generatedFlag(r.status),
                csv(r.confidence), r.topScore == null ? '' : String.valueOf(r.topScore),
                r.sourceCount == null ? '' : String.valueOf(r.sourceCount),
                r.draftChars == null ? '' : String.valueOf(r.draftChars),
                r.elapsedMs == null ? '' : String.valueOf(r.elapsedMs),
                csv(r.distill), csv(r.gateFlags),
                csv(r.createdDate), csv(r.product), csv(r.intake),
                '', '', '',                 // should_have_drafted / label / review_reason — reviewer-filled
                csv(r.caseNumber), csv(r.caseId), csv(r.subject), csv(r.status),
                csv(r.draftExcerpt), csv(r.notesExcerpt), csv(r.errorDetail)
            }, ','));
        }
        return String.join(lines, '\n');
    }

    /** RFC-4180-ish: quote when needed, double embedded quotes, flatten newlines for readability. */
    private static String csv(String s) {
        if (s == null) { return ''; }
        String flat = s.replace('\r\n', ' ').replace('\n', ' ').replace('\r', ' ');
        if (flat.contains(',') || flat.contains('"')) {
            return '"' + flat.replace('"', '""') + '"';
        }
        return flat;
    }

    private static String truncate(String s, Integer max) {
        if (s == null) { return null; }
        return s.length() > max ? s.substring(0, max) : s;
    }
}
