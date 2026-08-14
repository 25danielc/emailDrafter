/**
 * Real retrieve->draft integration passes: SOSL pinned via Test.setFixedSearchResults, generation
 * stubbed via the ModelClient seam (the stub records whether the metered call happened).
 */
@isTest
private class SupportDraftOrchestratorTest {

    // ---- stub model client (mirrors SupportDraftingServiceTest.StubClient) ----
    private class StubClient implements SupportDraftingService.ModelClient {
        public Boolean called = false;
        String response;
        StubClient(String r) { this.response = r; }
        public String generate(String modelName, String prompt) {
            called = true;
            return response;
        }
    }

    // The drafted reply is intentionally grounded in the seeded doc body ("Merge fields render blank in the
    // generated template document.") so it passes the new #3 grounding gate — a faithful model fed that
    // body would write exactly this kind of reply. Tests here assert routing/audit, not generation quality.
    private static String okJson() {
        return '{"draft":"Hi Dana, your merge fields render blank because the template field mapping is not '
            + 'populating; update the template configuration so the generated document shows the merge '
            + 'fields.","sources_used":"a01","agent_notes":"Standard fix.","confidence":"HIGH"}';
    }

    private static Support_Solution__c sol(String pageId, String name, String body, String product,
                                           String source, String keywords, String visibility) {
        return new Support_Solution__c(
            Name = name,
            Confluence_Page_Id__c = pageId,
            Body__c = body,
            Product__c = product,
            Source_Type__c = source,
            Keywords__c = keywords,
            Visibility__c = visibility,
            Confluence_URL__c = 'https://example.atlassian.net/wiki/' + pageId,
            Active__c = true
        );
    }

    private static SupportDraftOrchestrator.Request req(String subject, String description, String product) {
        SupportDraftOrchestrator.Request r = new SupportDraftOrchestrator.Request();
        r.subject = subject;
        r.description = description;
        r.product = product;
        r.customerName = 'Dana';
        return r;
    }

    /** Insert a single solution and pin it as the SOSL result set. */
    private static void seedAndPin(Support_Solution__c s) {
        insert s;
        Test.setFixedSearchResults(new List<Id>{ s.Id });
    }

    @isTest
    static void happyPathDraftsAndReturnsAuditFields() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        seedAndPin(sol('P1', 'Merge fields not populating',
            'Merge fields render blank in the generated template document.', 'S-Docs', 'canned',
            'merge fields blank template', 'customer_safe'));

        Test.startTest();
        SupportDraftOrchestrator.Result r =
            SupportDraftOrchestrator.orchestrate(req('Merge fields blank',
                'My generated document shows blank merge fields.', 'S-Docs'));
        Test.stopTest();

        System.assertEquals('DRAFTED', r.status, 'A customer-safe strong match should draft');
        System.assert(r.draftText != null && r.draftText.startsWith('Hi Dana'), 'Draft returned: ' + r.draftText);
        System.assertEquals(1, r.sourceIds.size(), 'The drafted-from solution is recorded for audit');
        System.assertEquals('sfdc_ai__DefaultGPT4Omni', r.modelName);
        System.assert(stub.called, 'A draftable case should make the one Models call');
    }

    @isTest
    static void escalateOnlyTopMatchRoutesToEscalateWithoutModelCall() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        seedAndPin(sol('E1', 'Corruption workaround',
            'widget corruption escalate to tier3 do not self serve', 'S-Docs', 'tips',
            'widget corruption', 'escalate_only'));

        SupportDraftOrchestrator.Result r =
            SupportDraftOrchestrator.orchestrate(req('widget corruption', 'document is corrupt', 'S-Docs'));

        System.assertEquals('ESCALATE', r.status, 'Escalate-only top match must flip to ESCALATE');
        System.assertEquals(null, r.draftText);
        System.assertEquals(false, stub.called, 'Escalation must NOT spend a metered Models call');
        System.assert(r.notes != null && r.notes.toLowerCase().contains('escalat'),
            'Notes explain the route: ' + r.notes);
    }

    @isTest
    static void noSoslMatchReturnsNoDraftNoMatch() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        insert sol('X1', 'Anything', 'some body text', 'S-Docs', 'canned', 'x', 'customer_safe');
        Test.setFixedSearchResults(new List<Id>()); // SOSL returns empty -> no candidates

        SupportDraftOrchestrator.Result r =
            SupportDraftOrchestrator.orchestrate(req('merge fields blank', 'blank fields', 'S-Docs'));

        System.assertEquals('NO_DRAFT_NO_MATCH', r.status);
        System.assertEquals(false, stub.called, 'No match must NOT call the model');
    }

    @isTest
    static void excludedShortCircuitsBeforeRetrievalAndModel() {
        // An excluded case (junk/billing intake, or a Flow-set flag) must return before ANY callout:
        // no SOSL/embedding/distill retrieval pass and no metered model call. NOT pinning fixed
        // search results proves retrieval never ran — a real SOSL here would throw in test context
        // without the pin only if executed... instead we assert on the audit trail: no distill note,
        // the excluded stamp, and an unspent model stub.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        SupportDraftOrchestrator.Request rq = req('Merge fields blank', 'blank merge fields', 'S-Docs');
        rq.excluded = true;
        rq.excludedReason = 'Billing/licensing: refund request';

        SupportDraftOrchestrator.Result r = SupportDraftOrchestrator.orchestrate(rq);

        System.assertEquals('NO_DRAFT_EXCLUDED', r.status, 'Excluded category short-circuits pre-retrieval');
        System.assertEquals('NONE', r.confidence);
        System.assert(r.notes.contains('Billing/licensing: refund request'),
            'The intake reason is preserved for the Case audit trail: ' + r.notes);
        System.assertEquals(null, r.retrievalTopScore, 'Retrieval never ran — no score recorded');
        System.assertEquals(false, stub.called, 'Excluded case must NOT call the model');
    }

    @isTest
    static void agentOnlyMatchesAreNotDrafted() {
        // Top match is agent_only (not escalate_only, not customer_safe): the orchestrator proceeds to
        // draft(), whose safety gate (D14) blocks generation -> NO_DRAFT_NO_MATCH, no model call.
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        seedAndPin(sol('A1', 'Internal merge note',
            'merge fields internal runbook for blank template debugging', 'S-Docs', 'tips',
            'merge fields blank template', 'agent_only'));

        SupportDraftOrchestrator.Result r =
            SupportDraftOrchestrator.orchestrate(req('Merge fields blank', 'blank merge fields', 'S-Docs'));

        System.assertEquals('NO_DRAFT_NO_MATCH', r.status, 'Non-customer-safe matches are not draft fuel');
        System.assertEquals(false, stub.called, 'No customer-safe fuel -> no model call');
    }

    @isTest
    static void invocableRunMapsRequestsToResults() {
        StubClient stub = new StubClient(okJson());
        SupportDraftingService.client = stub;

        seedAndPin(sol('P3', 'Merge fields not populating',
            'Merge fields render blank in the generated template document.', 'S-Docs', 'canned',
            'merge fields blank template', 'customer_safe'));

        Test.startTest();
        List<SupportDraftOrchestrator.Result> results = SupportDraftOrchestrator.run(
            new List<SupportDraftOrchestrator.Request>{
                req('Merge fields blank', 'blank merge fields', 'S-Docs')
            });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('DRAFTED', results[0].status);
    }

    @isTest
    static void nullRequestReturnsNoMatch() {
        SupportDraftOrchestrator.Result r = SupportDraftOrchestrator.orchestrate(null);
        System.assertEquals('NO_DRAFT_NO_MATCH', r.status);
    }

    // ---- unit tests on the mapping helpers ----

    @isTest
    static void blankProductSearchesBothAndJoinsCaseText() {
        SupportRetrievalService.RetrievalInput inp =
            SupportDraftOrchestrator.buildRetrievalInput(req('Signer email', 'did not receive it', '   '));
        System.assertEquals(null, inp.product, 'Blank Product_List__c -> null -> search both products');
        System.assert(inp.searchText.contains('Signer email'), 'Subject carried into search text');
        System.assert(inp.searchText.contains('did not receive it'), 'Description carried into search text');
    }

    @isTest
    static void mapCandidatesFeedsFullBodyNotSnippet() {
        // Regression: feeding the 300-char retrieval snippet starved the model and produced an empty
        // draft (NO_DRAFT_MODEL_ERROR). mapCandidates must resolve the full Body__c by Id instead.
        String longBody = '';
        for (Integer i = 0; i < 80; i++) { longBody += '0123456789'; } // 800 chars, > 300 snippet cap
        Support_Solution__c rec = sol('B1', 'Long doc', longBody, 'S-Docs', 'official', 'kw', 'customer_safe');
        insert rec;

        SupportRetrievalService.Candidate c = new SupportRetrievalService.Candidate();
        c.solutionId = rec.Id;
        c.visibility = 'customer_safe';
        c.snippet = longBody.substring(0, 300) + '...'; // what retrieval actually carries

        List<SupportDraftingService.SolutionContext> mapped =
            SupportDraftOrchestrator.mapCandidates(new List<SupportRetrievalService.Candidate>{ c });

        System.assertEquals(800, mapped[0].body.length(),
            'Full Body__c (800 chars) must be fed to drafting, not the 300-char snippet');
    }

    @isTest
    static void mapCandidatesCarriesGatingFields() {
        SupportRetrievalService.Candidate c = new SupportRetrievalService.Candidate();
        c.name = 'Sig fix';
        c.sourceType = 'canned';
        c.visibility = 'customer_safe';
        c.solutionType = 'template';
        c.hasRequiredDisclaimer = true;
        c.url = 'https://x';
        c.snippet = 'body text here';

        List<SupportDraftingService.SolutionContext> mapped =
            SupportDraftOrchestrator.mapCandidates(new List<SupportRetrievalService.Candidate>{ c });

        System.assertEquals(1, mapped.size());
        System.assertEquals('customer_safe', mapped[0].visibility, 'Safety axis must survive mapping');
        System.assertEquals('template', mapped[0].solutionType, 'Format axis must survive mapping');
        System.assertEquals(true, mapped[0].hasRequiredDisclaimer, 'Disclaimer flag must survive mapping');
        System.assertEquals('body text here', mapped[0].body, 'Retrieval snippet becomes drafting body');
    }
}
