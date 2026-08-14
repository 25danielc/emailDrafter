/**
 * Covers the common-case CSV seeding path (DQ rules, RFC4180 parsing) end-to-end through
 * SupportSolutionStore.upsertPages.
 */
@isTest
private class CaseSeedImporterTest {

    @isTest
    static void ingestAppliesAllDqRules() {
        List<CaseSeedImporter.CaseRow> rows = new List<CaseSeedImporter.CaseRow>{
            // answer row -> customer_safe, official, body = the June Gitbook answer
            new CaseSeedImporter.CaseRow('30617',
                'How do I make the attachment field visible so I can automate file attachments?',
                'Provided article and syntax',
                'Use Document Options then Attachment and File Options to enable Create Salesforce Attachment only when emailed.'),
            // glued-token row -> re-spaced Name, raw preserved
            new CaseSeedImporter.CaseRow('30623',
                'SDOC__Email_ReplyTo__cAPI field is mismatched — how do I resolve this?',
                'Caused by push upgrade',
                'Use the Email ReplyTo field on SDOC__SDTemplate__c whose API name is Email_ReplyTo.'),
            // normal answer row -> body = the June Gitbook answer (April/conflict handling is retired)
            new CaseSeedImporter.CaseRow('30618',
                'SDOC__SDTemplate__c error affecting multiple orgs — how do I fix this?',
                'Client upgraded',
                'Re-save the affected templates; check SDOC__Has_Error__c and toggle it back to false.'),
            // no-answer row ('--') -> agent_only, unsorted, empty body, still matchable on its issue text
            new CaseSeedImporter.CaseRow('30649',
                'How do I query the SDOC__Template_XML__c field to retrieve template data?',
                'Assisted client with SOQL', '--'),
            // ambiguous glued run -> needsReview
            new CaseSeedImporter.CaseRow('30627',
                'alignleftspecifiedinmycomponentloopbreaks the styles menu is overriding it',
                'Sent instructions',
                'Set the field Additional Style directly like width:100px;text-align:left; with semicolons.')
        };

        Test.startTest();
        CaseSeedImporter.SeedResult res = CaseSeedImporter.ingest(rows);
        Test.stopTest();

        System.assertEquals(5, res.processed, 'All five rows upserted');
        System.assertEquals(0, res.failed);
        System.assertEquals(1, res.noAnswer, 'One DQ-4 no-answer row');
        System.assert(res.needsReview.contains('30627'), 'The glued run must be flagged for re-export');

        Map<String, Support_Solution__c> byExt = new Map<String, Support_Solution__c>();
        for (Support_Solution__c s : [
                SELECT Confluence_Page_Id__c, Name, Body__c, Common_Case__c, Visibility__c,
                       Source_Type__c, Product__c
                FROM Support_Solution__c]) {
            byExt.put(s.Confluence_Page_Id__c, s);
        }

        // answer row
        Support_Solution__c a = byExt.get('sdocs-case-30617');
        System.assertEquals(true, a.Common_Case__c);
        System.assertEquals('customer_safe', a.Visibility__c);
        System.assertEquals('official', a.Source_Type__c);
        System.assert(a.Body__c.contains('Document Options'), 'Body must be the JUNE answer');

        // normalization: __c followed by a letter got a space in the searchable Name
        Support_Solution__c g = byExt.get('sdocs-case-30623');
        System.assert(g.Name.contains('SDOC__Email_ReplyTo__c API'), 'Glued token re-spaced in Name: ' + g.Name);

        // 30618: a normal case now; body is the June Gitbook answer, no April/conflict artifacts remain
        Support_Solution__c c = byExt.get('sdocs-case-30618');
        System.assert(c.Body__c.contains('Re-save'), 'Body is the June Gitbook answer');

        // no-answer
        Support_Solution__c na = byExt.get('sdocs-case-30649');
        System.assertEquals('agent_only', na.Visibility__c, 'No-answer row must not be customer-reply fuel');
        System.assertEquals('unsorted', na.Source_Type__c);
        System.assert(String.isBlank(na.Body__c), 'No-answer body must be empty (never surface a non-answer)');
        System.assertEquals(true, na.Common_Case__c, 'Still a common case (matchable on its issue text)');
    }

    @isTest
    static void ingestCsvParsesQuotedMultilineCells() {
        // A quoted answer cell with embedded commas, a newline, and an escaped "" quote must parse as ONE
        // field, and the header row must be skipped.
        String csv =
            'Case #,Issue / Question,Answer / Response Provided,Answer (JUNE),Answer (APRIL 8th)\n'
            + '30617,How do I attach the PDF?,internal note,'
            + '"Use Document Options, then Attachment Options.\nEnable ""only when emailed"" to automate it.",\n';

        Test.startTest();
        CaseSeedImporter.SeedResult res = CaseSeedImporter.ingestCsv(csv);
        Test.stopTest();

        System.assertEquals(1, res.processed, 'One data row (header skipped)');
        Support_Solution__c s = [
            SELECT Body__c, Common_Case__c, Visibility__c FROM Support_Solution__c
            WHERE Confluence_Page_Id__c = 'sdocs-case-30617' LIMIT 1];
        System.assert(s.Body__c.contains('Attachment Options'), 'Quoted comma field parsed whole');
        System.assert(s.Body__c.contains('only when emailed'), 'Escaped quotes decoded');
        System.assert(s.Body__c.contains('\n'), 'Embedded newline preserved inside the cell');
        System.assertEquals('customer_safe', s.Visibility__c);
    }

    @isTest
    static void blankCaseNumberIsReportedNotDropped() {
        CaseSeedImporter.SeedResult res = CaseSeedImporter.ingest(
            new List<CaseSeedImporter.CaseRow>{
                new CaseSeedImporter.CaseRow(null, 'orphan issue', 'n', 'an answer here') });
        System.assertEquals(1, res.failed);
        System.assertEquals(0, res.processed);
    }
}
