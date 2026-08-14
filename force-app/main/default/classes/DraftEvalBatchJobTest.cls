/**
 * The end-to-end test drives the REAL orchestrate() path (SOSL pinned, generation stubbed via the
 * ModelClient seam, embedding/distill forced off for determinism); the chunking and error-isolation
 * tests substitute the OrchestrateFn seam so no pipeline internals are exercised twice.
 */
@isTest
private class DraftEvalBatchJobTest {

    // ---- stub model client (same recipe as SupportDraftOrchestratorTest) ----
    private class StubClient implements SupportDraftingService.ModelClient {
        String response;
        StubClient(String r) { this.response = r; }
        public String generate(String modelName, String prompt) { return response; }
    }

    private static String okJson() {
        return '{"draft":"Hi there, your merge fields render blank because the template field mapping is '
            + 'not populating; update the template configuration so the generated document shows the '
            + 'merge fields.","sources_used":"a01","agent_notes":"Standard fix.","confidence":"HIGH"}';
    }

    private static Support_Solution__c seedSolution() {
        Support_Solution__c s = new Support_Solution__c(
            Name = 'Merge fields not populating',
            Confluence_Page_Id__c = 'EV1',
            Body__c = 'Merge fields render blank in the generated template document.',
            Product__c = 'S-Docs',
            Source_Type__c = 'canned',
            Keywords__c = 'merge fields blank template',
            Visibility__c = 'customer_safe',
            Confluence_URL__c = 'https://example.atlassian.net/wiki/EV1',
            Active__c = true
        );
        insert s;
        Test.setFixedSearchResults(new List<Id>{ s.Id });
        return s;
    }

    /** Origin=Web on purpose: the eval job must not depend on (or trigger) the Email flow path. */
    private static List<Case> seedCases(Integer n) {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < n; i++) {
            cases.add(new Case(
                Subject = 'Merge fields blank ' + i,
                Description = 'My generated document shows blank merge fields.',
                Origin = 'Web',
                Product_List__c = 'S-Docs'
            ));
        }
        insert cases;
        return cases;
    }

    private static List<Id> ids(List<Case> cases) {
        List<Id> out = new List<Id>();
        for (Case c : cases) { out.add(c.Id); }
        return out;
    }

    // ---- OrchestrateFn stubs ----

    private class CannedFn implements DraftEvalBatchJob.OrchestrateFn {
        public SupportDraftOrchestrator.Result call(SupportDraftOrchestrator.Request req) {
            SupportDraftOrchestrator.Result r = new SupportDraftOrchestrator.Result();
            r.status = 'DRAFTED';
            r.confidence = 'HIGH';
            r.retrievalTopScore = 0.83;
            r.draftText = 'Hi there, canned draft body.';
            r.notes = 'Explanation: canned.\nRetrieval used the LLM-distilled query "merge fields" '
                + '(it decisively beat the raw case text).';
            r.sourceIds = new List<String>{ 'a01000000000001' };
            return r;
        }
    }

    private class ThrowForSubjectFn implements DraftEvalBatchJob.OrchestrateFn {
        String needle;
        ThrowForSubjectFn(String needle) { this.needle = needle; }
        public SupportDraftOrchestrator.Result call(SupportDraftOrchestrator.Request req) {
            if (req.subject != null && req.subject.contains(needle)) {
                throw new IllegalArgumentException('boom for ' + needle);
            }
            return new CannedFn().call(req);
        }
    }

    // ---- tests ----

    @isTest
    static void endToEndSingleChunkWritesReportAndLeavesCasesUntouched() {
        SupportDraftingService.client = new StubClient(okJson());
        SupportRetrievalService.testForceEmbedding = false;   // deterministic lexical-only retrieval
        SupportRetrievalService.testForceQueryDistill = false;
        seedSolution();
        List<Case> cases = seedCases(2);
        DraftEvalBatchJob.CHUNK_SIZE = 10; // whole cohort in one execution

        Test.startTest();
        System.enqueueJob(new DraftEvalBatchJob(ids(cases), 'unit-e2e'));
        Test.stopTest();

        List<ContentVersion> cvs = [
            SELECT Title, VersionData FROM ContentVersion WHERE Title = 'Draft Eval unit-e2e'
        ];
        System.assertEquals(1, cvs.size(), 'One completed run writes exactly one report');
        String body = cvs[0].VersionData.toString();

        List<Case> fresh = [SELECT CaseNumber, AI_Draft_Status__c FROM Case WHERE Id IN :ids(cases)];
        for (Case c : fresh) {
            System.assertEquals(null, c.AI_Draft_Status__c, 'Dry run must never stamp the Case');
            System.assert(body.contains(c.CaseNumber), 'Every cohort case gets a row: ' + c.CaseNumber);
        }
        System.assert(body.contains('DRAFTED'), 'Real pipeline drafted from the seeded doc:\n' + body);
        System.assertEquals(0, [SELECT COUNT() FROM EmailMessage], 'Dry run publishes no draft emails');

        // New columns land in the CSV, and the companion full-text detail JSON is written alongside it.
        System.assert(body.contains('generated,confidence,topScore'), 'Reordered header present: ' + body);
        System.assert(body.contains('createdDate,product,intake'), 'createdDate column present: ' + body);
        System.assert(body.contains('yes'), 'A DRAFTED row reports generated=yes');
        List<ContentVersion> detail = [
            SELECT VersionData FROM ContentVersion WHERE Title = 'Draft Eval Detail unit-e2e'
        ];
        System.assertEquals(1, detail.size(), 'One completed run writes exactly one detail JSON');
        String json = detail[0].VersionData.toString();
        for (Case c : fresh) {
            System.assert(json.contains(c.CaseNumber), 'Detail JSON carries every case: ' + c.CaseNumber);
        }
        System.assert(json.contains('"generated"'), 'Detail JSON exposes the generated flag: ' + json);
    }

    @isTest
    static void errorRowIsIsolatedAndRunCompletes() {
        List<Case> cases = seedCases(2); // subjects '... 0' and '... 1'
        DraftEvalBatchJob.CHUNK_SIZE = 10;
        DraftEvalBatchJob.fn = new ThrowForSubjectFn('blank 1');

        new DraftEvalBatchJob(ids(cases), 'unit-err').execute(null);

        String body = [SELECT VersionData FROM ContentVersion WHERE Title = 'Draft Eval unit-err']
            .VersionData.toString();
        System.assert(body.contains('ERROR'), 'Throwing case is recorded as ERROR: ' + body);
        System.assert(body.contains('boom for blank 1'), 'errorDetail carries the message');
        System.assert(body.contains('DRAFTED'), 'The healthy case still produced a real row');
    }

    @isTest
    static void chunkCursorChainsAcrossExecutionsAndReportsOnce() {
        List<Case> cases = seedCases(2);
        DraftEvalBatchJob.CHUNK_SIZE = 1;
        DraftEvalBatchJob.fn = new CannedFn();
        List<Id> cohort = ids(cases);

        DraftEvalBatchJob first = new DraftEvalBatchJob(cohort, 'unit-chunk');
        first.execute(null); // processes case 0; re-enqueue suppressed by Test.isRunningTest guard
        System.assertEquals(0,
            [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'Draft Eval unit-chunk%'],
            'Mid-chain executions must not write a report');
        System.assertEquals(1, first.rows.size(), 'First chunk processed exactly CHUNK_SIZE cases');

        // Hand-build the continuation the guard suppressed (cursor=1, carrying the accumulated rows).
        new DraftEvalBatchJob(cohort, 1, 1, first.rows, 'unit-chunk').execute(null);
        String body = [SELECT VersionData FROM ContentVersion WHERE Title = 'Draft Eval unit-chunk']
            .VersionData.toString();
        for (Case c : [SELECT CaseNumber FROM Case WHERE Id IN :cohort]) {
            System.assert(body.contains(c.CaseNumber), 'Final report carries rows from BOTH chunks');
        }
        System.assert(body.contains('0.83'), 'Numeric topScore lands in the CSV');
        System.assert(body.contains(',won,'), 'Distill classification parsed from notes');
    }

    @isTest
    static void toCsvEscapesDelimitersQuotesAndNewlines() {
        DraftEvalBatchJob.Row r = new DraftEvalBatchJob.Row();
        r.caseId = '500000000000001';
        r.caseNumber = '00012345';
        r.subject = 'Broken, badly "quoted"\nsubject';
        r.status = 'DRAFTED';
        r.gateFlags = 'claims,verify';
        String csv = DraftEvalBatchJob.toCsv(
            new List<DraftEvalBatchJob.Row>{ r }, 'unit-csv', 1);

        System.assert(csv.contains('"Broken, badly ""quoted"" subject"'),
            'Comma field is quoted, quotes doubled, newline flattened: ' + csv);
        System.assert(csv.startsWith('# run=unit-csv cohort=1 rows=1'), 'Metadata line first: ' + csv);
        System.assert(csv.contains('generated,confidence,topScore,sourceCount,draftChars,elapsedMs,distill,gateFlags,'),
            'Header carries the gateFlags column: ' + csv);
        System.assert(csv.contains('"claims,verify"'),
            'Multi-flag gateFlags value is quoted intact: ' + csv);
        System.assert(csv.contains('caseNumber,caseId,subject,status,draftExcerpt,notesExcerpt,errorDetail'),
            'Trailing diagnostic columns present: ' + csv);
        System.assert(csv.contains('yes'), 'DRAFTED status derives generated=yes: ' + csv);
    }

    @isTest
    static void intakeClassificationExcludesJunkAndBillingFromOrchestration() {
        // Junk cases must never reach the orchestrator (no callouts spent); billing cases go in
        // pre-excluded; both stamp NO_DRAFT_EXCLUDED rows and a LEGIT-only denominator remains.
        Case junk = new Case(Subject = 'Automatic reply: out of office', Description = 'ooo',
            Origin = 'Web', Product_List__c = 'S-Docs', SuppliedEmail = 'user@corp.com');
        Case billing = new Case(Subject = 'Invoice for renewal',
            Description = 'Please send the invoice for our upcoming renewal.',
            Origin = 'Web', Product_List__c = 'S-Docs', SuppliedEmail = 'jane@customer.com');
        Case legit = new Case(Subject = 'Merge fields blank',
            Description = 'My generated document shows blank merge fields.',
            Origin = 'Web', Product_List__c = 'S-Docs', SuppliedEmail = 'jane@customer.com');
        insert new List<Case>{ junk, billing, legit };

        RecordingFn rec = new RecordingFn();
        DraftEvalBatchJob.fn = rec;
        DraftEvalBatchJob.CHUNK_SIZE = 10;

        new DraftEvalBatchJob(new List<Id>{ junk.Id, billing.Id, legit.Id }, 'unit-intake').execute(null);

        System.assertEquals(2, rec.seen.size(),
            'JUNK must be synthesized locally; BILLING and LEGIT reach the orchestrator seam');
        System.assertEquals(true, rec.excludedFlags.get('Invoice for renewal'),
            'Billing request arrives pre-excluded');
        System.assertEquals(null, rec.excludedFlags.get('Merge fields blank'),
            'Legit request arrives without the exclusion flag');

        String body = [SELECT VersionData FROM ContentVersion WHERE Title = 'Draft Eval unit-intake']
            .VersionData.toString();
        System.assert(body.contains(',JUNK,'), 'Junk row carries its intake verdict: ' + body);
        System.assert(body.contains('NO_DRAFT_EXCLUDED'), 'Junk/billing rows stamp the excluded status: ' + body);
        System.assert(body.contains(',BILLING,'), 'Billing row carries its intake verdict');
        System.assert(body.contains(',LEGIT,'), 'Legit row carries its intake verdict');
        System.assert(body.contains('Junk mail:'), 'Junk reason lands in notesExcerpt');
    }

    private class RecordingFn implements DraftEvalBatchJob.OrchestrateFn {
        List<String> seen = new List<String>();
        Map<String, Boolean> excludedFlags = new Map<String, Boolean>();
        public SupportDraftOrchestrator.Result call(SupportDraftOrchestrator.Request req) {
            seen.add(req.subject);
            excludedFlags.put(req.subject, req.excluded);
            SupportDraftOrchestrator.Result r = new SupportDraftOrchestrator.Result();
            r.status = (req.excluded == true) ? 'NO_DRAFT_EXCLUDED' : 'DRAFTED';
            r.confidence = (req.excluded == true) ? 'NONE' : 'HIGH';
            r.notes = (req.excluded == true) ? 'Excluded category: ' + req.excludedReason : 'ok';
            return r;
        }
    }

    @isTest
    static void classifyDistillMatchesTheTwoStablePhrasings() {
        System.assertEquals('won', DraftEvalBatchJob.classifyDistill(
            'x\nRetrieval used the LLM-distilled query "q" (it decisively beat the raw case text).'));
        System.assertEquals('tried', DraftEvalBatchJob.classifyDistill(
            'An LLM-distilled retrieval query ("q") was tried but did not decisively beat the raw case text; kept.'));
        System.assertEquals('no', DraftEvalBatchJob.classifyDistill('plain notes'));
        System.assertEquals('no', DraftEvalBatchJob.classifyDistill(null));
    }
}
