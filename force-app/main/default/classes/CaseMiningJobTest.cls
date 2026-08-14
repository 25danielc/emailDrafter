/**
 * Drives the three-phase state machine with the Llm/embedder seams stubbed and the chain executed
 * by hand (enqueue is suppressed under test, mirroring DraftEvalBatchJobTest). SOSL is pinned empty
 * so the dedupe gate never fires unless a test pins a real doc.
 */
@isTest
private class CaseMiningJobTest {

    // ---- stubs ----

    /** Scripted LLM: routes by prompt shape (extract / generate / verify). */
    private class StubLlm implements CaseMiningJob.Llm {
        Boolean substantive = true;
        Boolean generateSkips = false;
        Boolean verifySupports = true;
        Integer extracts = 0, generates = 0, verifies = 0;
        public String complete(String modelName, String prompt) {
            if (prompt.startsWith('You extract')) {
                extracts++;
                return '{"question_summary":"How do I fix the widget merge error?",'
                    + '"resolution_summary":"Enable the widget setting under Setup and regenerate.",'
                    + '"substantive":' + substantive + ',"error_strings":["WIDGET_MERGE_FAIL"],'
                    + '"product":"S-Docs"}';
            }
            if (prompt.startsWith('You write')) {
                generates++;
                if (generateSkips) { return 'SKIP'; }
                return '```json\n{"title":"Widget merge error when generating documents",'
                    + '"problem":"Generating a document fails with the error WIDGET_MERGE_FAIL when '
                    + 'the widget setting is disabled in the org. The document run stops before any '
                    + 'output file is produced and the same error appears on every retry.",'
                    + '"cause":"The widget integration setting is disabled.",'
                    + '"resolution":"1. Open Setup. 2. Enable the widget setting. 3. Regenerate the '
                    + 'document. The agent confirmed the error clears once the setting is enabled and '
                    + 'the document generates normally afterward.",'
                    + '"keywords":"widget merge fail generate"}\n```';
            }
            verifies++;
            return verifySupports
                ? '{"verdict":"SUPPORTED","unsupported_claims":[]}'
                : '{"verdict":"UNSUPPORTED","unsupported_claims":["step 2 invented"]}';
        }
    }

    private class StubEmbedder implements SupportRetrievalService.EmbeddingClient {
        // All texts embed to the same vector -> everything clusters together.
        public List<List<Double>> embed(String modelName, List<String> texts) {
            List<List<Double>> out = new List<List<Double>>();
            for (Integer i = 0; i < texts.size(); i++) { out.add(new List<Double>{ 1, 0 }); }
            return out;
        }
    }

    // ---- fixtures ----

    private static List<Case> seedClosedCases(Integer n, String subjectStem) {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < n; i++) {
            cases.add(new Case(
                Subject = subjectStem + ' ' + i,
                Description = 'When generating, we get WIDGET_MERGE_FAIL and the document stops.',
                Origin = 'Web',
                Status = 'Closed',
                Product_List__c = 'S-Docs',
                SuppliedEmail = 'jane@customer.com'
            ));
        }
        insert cases;
        List<EmailMessage> replies = new List<EmailMessage>();
        for (Case c : cases) {
            replies.add(new EmailMessage(
                ParentId = c.Id,
                Incoming = false,
                Status = '3',
                TextBody = 'Hi Jane, this error means the widget setting is disabled. Please open '
                    + 'Setup, enable the widget setting, and regenerate the document. That resolves '
                    + 'the WIDGET_MERGE_FAIL error you are seeing. Let us know if it persists after '
                    + 'the setting change and we can take another look at the template itself.'
            ));
        }
        insert replies;
        return cases;
    }

    private static List<Id> ids(List<Case> cases) {
        List<Id> out = new List<Id>();
        for (Case c : cases) { out.add(c.Id); }
        return out;
    }

    /** Run the full chain by hand: HARVEST links until exhausted, then CLUSTER, then GENERATE links. */
    private static void runChain(List<Id> cohort, List<CaseMiningJob.SeedTopic> seeds, String label) {
        // execute() re-enqueues are suppressed under test; drive phases via the shared State.
        CaseMiningJob.State s = new CaseMiningJob.State();
        s.runLabel = label;
        s.cohort = cohort;
        s.seeds = seeds;
        // HARVEST: chunk through the cohort.
        Integer cursor = 0;
        while (cursor < cohort.size()) {
            s.phase = 'HARVEST'; s.cursor = cursor;
            new CaseMiningJob(s).execute(null);
            cursor += 5; s.depth++;
        }
        s.phase = 'CLUSTER'; s.cursor = 0;
        new CaseMiningJob(s).execute(null);
        s.depth++;
        cursor = 0;
        while (cursor == 0 || cursor < s.clusters.size()) {
            s.phase = 'GENERATE'; s.cursor = cursor;
            new CaseMiningJob(s).execute(null);
            cursor += 3; s.depth++;
            if (cursor >= s.clusters.size()) { break; }
        }
    }

    // ---- tests ----

    @isTest
    static void endToEndMinesOneDocFromRecurringCluster() {
        StubLlm stub = new StubLlm();
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        Test.setFixedSearchResults(new List<Id>()); // dedupe gate: existing corpus has nothing

        List<Case> cases = seedClosedCases(3, 'Widget merge fail');

        Test.startTest();
        runChain(ids(cases), new List<CaseMiningJob.SeedTopic>(), 'unit-e2e');
        Test.stopTest();

        List<Support_Solution__c> docs = [
            SELECT Name, Body__c, Visibility__c, Source_Type__c, Source_Space_Key__c, Product__c,
                   Active__c, Common_Case__c, Mined_From_Cases__c, Keywords__c, Embedding_Synced__c
            FROM Support_Solution__c WHERE Source_Space_Key__c = 'case-mined'
        ];
        System.assertEquals(1, docs.size(), '3 same-topic cases -> 1 cluster -> 1 doc');
        Support_Solution__c d = docs[0];
        System.assertEquals('customer_safe', d.Visibility__c, 'Mined docs must be draft fuel');
        System.assertEquals('tribal', d.Source_Type__c, 'Agent-reply-derived trust tier');
        System.assertEquals('S-Docs', d.Product__c);
        System.assertEquals(true, d.Active__c);
        System.assertEquals(false, d.Common_Case__c, '3 members < 4 -> not priority-eligible');
        System.assert(d.Body__c.contains('Problem') && d.Body__c.contains('Resolution'),
            'Sectioned body: ' + d.Body__c);
        System.assert(d.Mined_From_Cases__c.split(',').size() == 3,
            'Provenance carries all member case numbers: ' + d.Mined_From_Cases__c);
        System.assert(d.Keywords__c.contains('WIDGET_MERGE_FAIL'),
            'Verbatim error string lands in keywords');
        System.assertEquals(false, d.Embedding_Synced__c, 'New doc awaits the embedding backfill');
        System.assertEquals(3, stub.extracts, 'One extraction call per case');
        System.assertEquals(1, stub.generates, 'One generation call per cluster');
        System.assertEquals(1, stub.verifies, 'One verify call per generated doc');

        List<ContentVersion> report = [
            SELECT VersionData FROM ContentVersion WHERE Title = 'Case Mining unit-e2e'
        ];
        System.assertEquals(1, report.size(), 'Final report written');
        System.assert(report[0].VersionData.toString().contains('ACCEPTED'), 'Outcome recorded');
    }

    @isTest
    static void verifierRejectionBlocksIngestion() {
        StubLlm stub = new StubLlm();
        stub.verifySupports = false;
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        Test.setFixedSearchResults(new List<Id>());

        List<Case> cases = seedClosedCases(2, 'Widget merge fail');
        Test.startTest();
        runChain(ids(cases), new List<CaseMiningJob.SeedTopic>(), 'unit-verify');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Support_Solution__c
            WHERE Source_Space_Key__c = 'case-mined'],
            'An unsupported doc must never be ingested');
        String report = [SELECT VersionData FROM ContentVersion WHERE Title = 'Case Mining unit-verify']
            .VersionData.toString();
        System.assert(report.contains('REJECT_UNSUPPORTED'), 'Rejection is auditable: ' + report);
    }

    @isTest
    static void seedTopicClaimsMatchingCasesAndUnmatchedSeedIsFlagged() {
        StubLlm stub = new StubLlm();
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        Test.setFixedSearchResults(new List<Id>());

        List<Case> cases = seedClosedCases(2, 'Widget merge fail');
        List<CaseMiningJob.SeedTopic> seeds = new List<CaseMiningJob.SeedTopic>{
            new CaseMiningJob.SeedTopic('widget-merge-fail', 'Widget merge failure',
                new List<String>{ 'WIDGET_MERGE_FAIL' }, 'S-Docs'),
            new CaseMiningJob.SeedTopic('zqu-quote-missing', 'zqu_Quote__c missing object',
                new List<String>{ 'zqu_Quote__c' }, 'S-Docs')
        };

        Test.startTest();
        runChain(ids(cases), seeds, 'unit-seed');
        Test.stopTest();

        List<Support_Solution__c> docs = [
            SELECT Confluence_Page_Id__c FROM Support_Solution__c
            WHERE Source_Space_Key__c = 'case-mined'
        ];
        System.assertEquals(1, docs.size(), 'The matched seed produced one doc');
        System.assertEquals('case-mined:seed:widget-merge-fail', docs[0].Confluence_Page_Id__c,
            'Seed docs use the deterministic seed pageId');
        String report = [SELECT VersionData FROM ContentVersion WHERE Title = 'Case Mining unit-seed']
            .VersionData.toString();
        System.assert(report.contains('SEED_UNMATCHED') && report.contains('zqu-quote-missing'),
            'A groundless seed produces NO doc and is flagged for a human: ' + report);
    }

    @isTest
    static void dedupeGateSkipsWhenExistingCorpusAnswers() {
        StubLlm stub = new StubLlm();
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        // Pin the skip bar low: this test exercises the dedupe MECHANIC, not the live calibration.
        CaseMiningJob.DEDUPE_SKIP_SCORE = 0.10;

        // A strong existing (non-mined) doc that answers the cluster's question.
        Support_Solution__c existing = new Support_Solution__c(
            Name = 'Widget merge error fix',
            Confluence_Page_Id__c = 'HELP1',
            Body__c = 'How do I fix the widget merge error? Enable the widget setting and regenerate.',
            Product__c = 'S-Docs',
            Source_Type__c = 'official',
            Keywords__c = 'widget merge error fix',
            Visibility__c = 'customer_safe',
            Source_Space_Key__c = 'sdocs',
            Active__c = true
        );
        insert existing;
        Test.setFixedSearchResults(new List<Id>{ existing.Id });

        List<Case> cases = seedClosedCases(2, 'Widget merge fail');
        Test.startTest();
        runChain(ids(cases), new List<CaseMiningJob.SeedTopic>(), 'unit-dedupe');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Support_Solution__c
            WHERE Source_Space_Key__c = 'case-mined'],
            'No mined doc when the existing corpus already answers at the draft floor');
        System.assertEquals(0, stub.generates, 'Dedupe fires BEFORE generation is paid for');
        String report = [SELECT VersionData FROM ContentVersion WHERE Title = 'Case Mining unit-dedupe']
            .VersionData.toString();
        System.assert(report.contains('SKIP_DUPLICATE'), report);
    }

    @isTest
    static void junkAndNoReplyCasesNeverReachExtraction() {
        StubLlm stub = new StubLlm();
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        Test.setFixedSearchResults(new List<Id>());

        Case junk = new Case(Subject = 'Automatic reply: out of office', Description = 'ooo',
            Origin = 'Web', Status = 'Closed', Product_List__c = 'S-Docs',
            SuppliedEmail = 'noreply@corp.com');
        Case noReply = new Case(Subject = 'Widget question', Description = 'How does the widget work?',
            Origin = 'Web', Status = 'Closed', Product_List__c = 'S-Docs',
            SuppliedEmail = 'jane@customer.com');
        insert new List<Case>{ junk, noReply }; // neither has an outbound reply >= 200 chars

        Test.startTest();
        runChain(new List<Id>{ junk.Id, noReply.Id }, new List<CaseMiningJob.SeedTopic>(), 'unit-skip');
        Test.stopTest();

        System.assertEquals(0, stub.extracts, 'Junk / reply-less cases spend zero LLM callouts');
        System.assertEquals(0, [SELECT COUNT() FROM Support_Solution__c
            WHERE Source_Space_Key__c = 'case-mined']);
    }

    @isTest
    static void nonSubstantiveExtractionIsDropped() {
        StubLlm stub = new StubLlm();
        stub.substantive = false;
        CaseMiningJob.llm = stub;
        CaseMiningJob.embedder = new StubEmbedder();
        Test.setFixedSearchResults(new List<Id>());

        List<Case> cases = seedClosedCases(2, 'Widget merge fail');
        Test.startTest();
        runChain(ids(cases), new List<CaseMiningJob.SeedTopic>(), 'unit-nonsub');
        Test.stopTest();

        System.assertEquals(2, stub.extracts, 'Extraction ran');
        System.assertEquals(0, stub.generates, 'Nothing substantive -> no clusters -> no generation');
        System.assertEquals(0, [SELECT COUNT() FROM Support_Solution__c
            WHERE Source_Space_Key__c = 'case-mined']);
    }

    // ---- unit tests on pure helpers ----

    @isTest
    static void scrubPiiRedactsEmailsPhonesAndForeignUrls() {
        String scrubbed = CaseMiningJob.scrubPii(
            'Contact jane.doe@customer.com or +1 (555) 123-4567. See https://customer-org.my.site.com/x '
            + 'and https://help.sdocs.com/article and version 8.0.12 remains.');
        System.assert(!scrubbed.contains('jane.doe@customer.com'), scrubbed);
        System.assert(scrubbed.contains('[email removed]'), scrubbed);
        System.assert(!scrubbed.contains('555) 123-4567'), scrubbed);
        System.assert(scrubbed.contains('[phone removed]'), scrubbed);
        System.assert(!scrubbed.contains('customer-org.my.site.com'), 'Foreign URL stripped: ' + scrubbed);
        System.assert(scrubbed.contains('https://help.sdocs.com/article'), 'Allowlisted URL kept');
        System.assert(scrubbed.contains('8.0.12'), 'Version strings are not phones');
    }

    @isTest
    static void stripQuotedHistoryCutsAtReplyMarkers() {
        String agent = 'Please enable the setting and regenerate.';
        System.assertEquals(agent, CaseMiningJob.stripQuotedHistory(
            agent + '\nFrom: Jane <jane@customer.com>\nSent: Monday\nOriginal question here'));
        System.assertEquals(agent, CaseMiningJob.stripQuotedHistory(
            agent + '\nOn Mon, Jul 1, Jane wrote:\n> original text'));
        System.assert(CaseMiningJob.stripQuotedHistory(
            'One thing to note.\nOn the settings page, click save.').contains('settings page'),
            '"On " without "wrote:" is prose, not a reply header');
    }

    @isTest
    static void cosineAndSeedMatchingBehave() {
        System.assertEquals(1.0, CaseMiningJob.cosine(
            new List<Double>{ 1, 0 }, new List<Double>{ 2, 0 }), 'Parallel vectors -> 1');
        System.assert(CaseMiningJob.cosine(
            new List<Double>{ 1, 0 }, new List<Double>{ 0, 1 }) < 0.0001, 'Orthogonal -> 0');
        System.assertEquals(-1, CaseMiningJob.cosine(null, new List<Double>{ 1 }), 'null -> N/A');

        CaseMiningJob.HarvestRow row = new CaseMiningJob.HarvestRow();
        row.subject = 'Error generating';
        row.question = 'Job fails with SDTemplate__c sObject type not supported';
        CaseMiningJob.SeedTopic seed = new CaseMiningJob.SeedTopic('sdtemplate', 'SDTemplate error',
            new List<String>{ 'sdtemplate__c sobject type not supported' }, 'S-Docs');
        System.assertEquals(true, CaseMiningJob.rowMatchesSeed(row, seed), 'Case-insensitive contains');
        seed.searchTerms = new List<String>{ 'zqu_Quote__c' };
        System.assertEquals(false, CaseMiningJob.rowMatchesSeed(row, seed));
    }

    @isTest
    static void gateCheckEnforcesShapeAndSize() {
        Map<String, Object> doc = new Map<String, Object>{
            'problem' => 'p', 'resolution' => 'r' };
        System.assert(CaseMiningJob.gateCheck(doc, 'short').contains('too short'));
        String body = CaseMiningJob.buildBody(new Map<String, Object>{
            'problem' => 'A detailed problem statement that describes the symptom the customer sees '
                + 'when the widget setting is disabled and generation halts with an error code.',
            'cause' => 'Setting disabled.',
            'resolution' => 'A detailed resolution with numbered steps: 1. Open Setup. 2. Enable the '
                + 'widget setting. 3. Regenerate the document and confirm the error is resolved.' });
        System.assertEquals(null, CaseMiningJob.gateCheck(doc, body), 'Well-formed body passes');
        System.assert(CaseMiningJob.buildBody(new Map<String, Object>{
            'problem' => 'p', 'cause' => '', 'resolution' => 'r' }).contains('Problem\np'),
            'Blank cause section is omitted');
    }
}
