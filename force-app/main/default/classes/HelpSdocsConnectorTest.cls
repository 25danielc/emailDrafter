/**
 * Covers the help.sdocs connector: client + classifier + sync service + sync queueable. The
 * Transport seam is faked (no network). Each section uses its own fake (the sitemap/markdown
 * bodies differ): ClientFakeTransport / SyncFakeTransport / QueueFakeTransport. One live
 * RestTransport pass runs behind an HttpCalloutMock.
 */
@isTest
private class HelpSdocsConnectorTest {

    // ===================================================================================================
    // Client
    // ===================================================================================================

    /** Fake transport: returns sitemap XML for *sitemap* URLs and markdown for *.md URLs. */
    private class ClientFakeTransport implements HelpSdocsConnector.Transport {
        public String get(String url) {
            if (url.endsWith('sitemap-pages.xml')) { return sitemapXml(); }
            if (url.endsWith('.md')) { return markdownBody(); }
            throw new HelpSdocsConnector.HelpSdocsException('unexpected url ' + url);
        }
    }

    /** HttpCalloutMock to exercise the real RestTransport callout path. */
    private class HttpMock implements HttpCalloutMock {
        Integer code; String body;
        HttpMock(Integer c, String b) { this.code = c; this.body = b; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(code);
            r.setBody(body);
            return r;
        }
    }

    private static String sitemapXml() {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            + '<url><loc>https://help.sdocs.com/s-sign/cfg/customize-s-sign-fields-and-inputs</loc>'
            + '<priority>0.84</priority><lastmod>2026-03-25T21:42:58.442Z</lastmod></url>'
            + '<url><loc>https://help.sdocs.com/s-sign/s-sign-with-pdf-upload</loc>'
            + '<lastmod>2026-04-02T18:58:24.879Z</lastmod></url>'
            + '</urlset>';
    }

    private static String markdownBody() {
        return '> For the complete documentation index, see [llms.txt](https://help.sdocs.com/llms.txt). '
            + 'Markdown versions of documentation pages are available by appending `.md` to page URLs; '
            + 'this page is available as [Markdown](https://help.sdocs.com/x.md).\n\n'
            + '# S-Sign with PDF-Upload\n\nConfigure signature fields on an uploaded PDF.';
    }

    @isTest
    static void listUrlsParsesLocAndLastmod() {
        HelpSdocsConnector.http = new ClientFakeTransport();
        List<HelpSdocsConnector.UrlRef> refs = HelpSdocsConnector.listUrls(new List<String>{ 's-sign' });
        System.assertEquals(2, refs.size(), 'two <loc> entries parsed');
        System.assertEquals('https://help.sdocs.com/s-sign/cfg/customize-s-sign-fields-and-inputs',
            refs[0].url);
        System.assertEquals('s-sign', refs[0].section);
        System.assertNotEquals(null, refs[0].lastModified, '<lastmod> parsed to Datetime');
    }

    @isTest
    static void listUrlsDefaultsToAllSections() {
        HelpSdocsConnector.http = new ClientFakeTransport();
        // null sections -> DEFAULT_SECTIONS (4 sections, 2 urls each from the fake) = 8 refs.
        List<HelpSdocsConnector.UrlRef> refs = HelpSdocsConnector.listUrls(null);
        System.assertEquals(HelpSdocsConnector.DEFAULT_SECTIONS.size() * 2, refs.size());
    }

    @isTest
    static void fetchPageCleansBoilerplateAndDerivesIdTitle() {
        HelpSdocsConnector.http = new ClientFakeTransport();
        HelpSdocsConnector.UrlRef ref = new HelpSdocsConnector.UrlRef(
            'https://help.sdocs.com/s-sign/s-sign-with-pdf-upload', 's-sign', null);

        HelpSdocsConnector.DocPage dp = HelpSdocsConnector.fetchPage(ref);

        System.assertEquals('s-sign/s-sign-with-pdf-upload', dp.id, 'external id is the URL path');
        System.assertEquals('S-Sign with PDF-Upload', dp.title, 'title from first H1');
        System.assert(dp.markdown.startsWith('# S-Sign with PDF-Upload'),
            'leading llms.txt boilerplate blockquote stripped: ' + dp.markdown.left(40));
        System.assert(!dp.markdown.contains('llms.txt'), 'boilerplate fully removed');
    }

    @isTest
    static void cleanMarkdownStripsGitbookNoise() {
        String raw = '# T\n\n{% hint style="info" %}\n**Note:** keep me\n{% endhint %}\n\n'
            + 'Col A &#124; Col B\n\n1\\. first\n2\\. second';
        String out = HelpSdocsConnector.cleanMarkdown(raw);
        System.assert(!out.contains('{%'), 'Liquid macros removed: ' + out);
        System.assert(out.contains('**Note:** keep me'), 'hint inner text kept: ' + out);
        System.assert(out.contains('Col A | Col B'), 'numeric pipe entity decoded: ' + out);
        System.assert(!out.contains('&#124;'), 'entity fully decoded');
        System.assert(out.contains('1. first'), 'escaped list marker unescaped: ' + out);
        // {{ merge fields }} must survive (real content in S-Docs docs).
        System.assertEquals('Use {{Account.Name}} here',
            HelpSdocsConnector.cleanMarkdown('Use {{Account.Name}} here'));
    }

    @isTest
    static void realTransportSuccessAndNon200() {
        // Success path through RestTransport (default http seam).
        Test.setMock(HttpCalloutMock.class, new HttpMock(200, sitemapXml()));
        Test.startTest();
        List<HelpSdocsConnector.UrlRef> refs = HelpSdocsConnector.listUrls(new List<String>{ 's-sign' });
        Test.stopTest();
        System.assertEquals(2, refs.size());

        // Non-200 path surfaces a HelpSdocsException.
        Test.setMock(HttpCalloutMock.class, new HttpMock(404, 'nope'));
        Boolean threw = false;
        try {
            HelpSdocsConnector.listUrls(new List<String>{ 's-sign' });
        } catch (HelpSdocsConnector.HelpSdocsException e) {
            threw = true;
            System.assert(e.getMessage().contains('404'), 'status surfaced: ' + e.getMessage());
        }
        System.assertEquals(true, threw, 'non-200 must raise HelpSdocsException');
    }

    // ===================================================================================================
    // Classifier
    // ===================================================================================================

    private static HelpSdocsConnector.PageContent page(String body) {
        HelpSdocsConnector.PageContent p = new HelpSdocsConnector.PageContent();
        p.title = 'T';
        p.sectionKey = 'sdocs';
        p.body = body;
        p.labels = new List<String>();
        return p;
    }

    @isTest
    static void parseNormalizesToDeployedVocab() {
        String raw =
            '{"product":{"value":"S-Docs","confidence":0.98,"rationale":"merge fields"},' +
            ' "format":{"value":"How-To","confidence":0.9,"rationale":"steps"},' +
            ' "trust":{"value":"Official","confidence":0.9,"rationale":"published"},' +
            ' "topic":{"area":"Templates & Merge Fields","detail":"insert merge field","confidence":0.9,"rationale":"x"},' +
            ' "audience":{"value":"customer","confidence":0.85,"rationale":"end user"},' +
            ' "visibility":{"value":"customer_safe","confidence":0.91,"rationale":"product help"}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('S-Docs', c.product);
        System.assertEquals('how_to', c.contentFormat, 'How-To -> how_to');
        System.assertEquals('official', c.sourceType);
        System.assertEquals('templates_merge_fields', c.topicArea, 'label normalized to api value');
        System.assertEquals('insert merge field', c.topicDetail);
        System.assertEquals('customer', c.audience);
        System.assertEquals('customer_safe', c.visibility);
        System.assertEquals(0.91, c.visibilityConfidence);
        System.assertEquals('procedure', HelpSdocsConnector.solutionTypeFor(c.contentFormat));
    }

    @isTest
    static void guardBlocksCustomerSafeWhenProductNone() {
        String raw =
            '{"product":{"value":"None"},"format":{"value":"concept"},"trust":{"value":"internal_ops"},' +
            ' "topic":{"area":"other","detail":"hr"},"audience":{"value":"agent"},' +
            ' "visibility":{"value":"customer_safe","confidence":0.7}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('None', c.product);
        System.assertEquals('agent_only', c.visibility, 'product None forces agent_only over model output');
    }

    @isTest
    static void floorDemotesLowConfidenceCustomerSafe() {
        // Clean product help, but the model's visibility confidence is below the 0.80 floor.
        String raw =
            '{"product":{"value":"S-Docs"},"format":{"value":"how_to"},"trust":{"value":"official"},' +
            ' "topic":{"area":"templates_merge_fields","detail":"x"},"audience":{"value":"customer","confidence":0.9},' +
            ' "red_flags":[],"visibility":{"value":"customer_safe","confidence":0.75}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('customer_safe', c.proposedVisibility, 'model proposal preserved for audit');
        System.assertEquals('agent_only', c.visibility, 'below the 0.80 floor -> demoted by the gate');
    }

    @isTest
    static void redFlagDemotesCustomerSafeEvenAtHighConfidence() {
        // The CS#10 pattern: agent-facing S-Docs reference carrying a "do not send" caveat.
        String raw =
            '{"product":{"value":"S-Docs"},"format":{"value":"reference"},"trust":{"value":"internal_ops"},' +
            ' "topic":{"area":"billing_licensing","detail":"document limit"},"audience":{"value":"agent","confidence":0.8},' +
            ' "red_flags":["\'do not send\' caveat in body"],"visibility":{"value":"customer_safe","confidence":0.95}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals(1, c.redFlags.size(), 'red_flags array parsed');
        System.assertEquals('agent_only', c.visibility, 'a non-empty red_flag is dispositive regardless of confidence');
    }

    @isTest
    static void strictAudienceDemotesAgentVoicedPage() {
        // audience=agent (not customer) must not commit customer_safe under the strict {customer} knob.
        String raw =
            '{"product":{"value":"S-Docs"},"format":{"value":"troubleshooting"},"trust":{"value":"official"},' +
            ' "topic":{"area":"errors_troubleshooting","detail":"x"},"audience":{"value":"agent","confidence":0.9},' +
            ' "red_flags":[],"visibility":{"value":"customer_safe","confidence":0.9}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('agent_only', c.visibility, 'audience!=customer -> demoted under strict knob');
    }

    @isTest
    static void cleanCustomerSafeCommits() {
        String raw =
            '{"product":{"value":"S-Docs"},"format":{"value":"how_to"},"trust":{"value":"official"},' +
            ' "topic":{"area":"templates_merge_fields","detail":"insert merge field"},' +
            ' "audience":{"value":"customer","confidence":0.92},' +
            ' "red_flags":[],"visibility":{"value":"customer_safe","confidence":0.9}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals(true, c.redFlags.isEmpty(), 'no red flags');
        System.assertEquals('customer_safe', c.visibility, 'all gate conditions hold -> customer_safe');
    }

    @isTest
    static void escalateOnlyProposalIsPreserved() {
        String raw =
            '{"product":{"value":"S-Sign"},"format":{"value":"troubleshooting"},"trust":{"value":"official"},' +
            ' "topic":{"area":"e_signature","detail":"x"},"audience":{"value":"agent","confidence":0.8},' +
            ' "red_flags":[],"visibility":{"value":"escalate_only","confidence":0.9}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('escalate_only', c.visibility, 'escalate_only routing hand-off preserved by the gate');
    }

    @isTest
    static void parseToleratesMarkdownFenceAndUnknownVocab() {
        String raw = '```json\n{"product":{"value":"banana"},"format":{"value":"wat"},' +
            '"trust":{"value":"zzz"},"audience":{"value":"qqq"},"visibility":{"value":"qqq"}}\n```';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals('None', c.product, 'unknown product -> None');
        System.assertEquals(null, c.contentFormat, 'unknown format -> null');
        System.assertEquals('unsorted', c.sourceType, 'unknown trust -> unsorted');
        System.assertEquals('internal', c.audience, 'unknown audience -> internal');
        System.assertEquals('agent_only', c.visibility, 'unknown visibility -> agent_only');
        System.assertEquals('other', c.topicArea, 'missing topic -> other');
    }

    @isTest
    static void parseExtractsAndNormalizesKeywords() {
        String raw =
            '{"product":{"value":"S-Sign"},"format":{"value":"how_to"},"trust":{"value":"official"},' +
            ' "topic":{"area":"e_signature","detail":"x"},"audience":{"value":"customer","confidence":0.9},' +
            ' "red_flags":[],"keywords":["Void Request","void request","e-signature","   ","recipient routing"],' +
            ' "visibility":{"value":"customer_safe","confidence":0.9}}';

        HelpSdocsConnector.Classification c = HelpSdocsConnector.parse(raw);

        System.assertEquals(3, c.keywords.size(), 'lowercased+deduped (Void Request==void request), blank dropped');
        System.assert(c.keywords.contains('void request'), 'lowercased');
        System.assert(c.keywords.contains('recipient routing'));
    }

    @isTest
    static void parseReturnsNullOnGarbage() {
        System.assertEquals(null, HelpSdocsConnector.parse('not json at all'));
        System.assertEquals(null, HelpSdocsConnector.parse(''));
    }

    @isTest
    static void heuristicFallbackDetectsProductWithoutCallout() {
        // classify with doClassify=false never calls out; product comes from keyword detection.
        HelpSdocsConnector.Classification both =
            HelpSdocsConnector.classify(page('<p>S-Docs and S-Sign</p>'), 'S-Docs', false);
        System.assertEquals('Both', both.product, 'both keywords -> Both (split signal)');
        System.assertEquals(null, both.visibility, 'heuristic leaves visibility null -> safe default at upsert');

        HelpSdocsConnector.Classification sdoc =
            HelpSdocsConnector.classify(page('<p>about S-Docs</p>'), 'S-Sign', false);
        System.assertEquals('S-Docs', sdoc.product);

        HelpSdocsConnector.Classification neither =
            HelpSdocsConnector.classify(page('<p>about nothing</p>'), 'S-Sign', false);
        System.assertEquals('S-Sign', neither.product, 'neither keyword -> default product');
    }

    @isTest
    static void liveBranchParsesMockRawResponse() {
        // doClassify=true with no mockResult enters the live branch; mockRawResponse feeds the parse
        // path (and exercises buildPrompt + hasCalloutBudget) without the actual ModelsAPI callout.
        HelpSdocsConnector.mockRawResponse =
            '{"product":{"value":"S-Sign"},"format":{"value":"troubleshooting"},' +
            '"trust":{"value":"official"},"topic":{"area":"e_signature","detail":"email not received"},' +
            '"audience":{"value":"customer"},"visibility":{"value":"customer_safe","confidence":0.88}}';

        HelpSdocsConnector.Classification c =
            HelpSdocsConnector.classify(page('<p>S-Sign envelope recipients</p>'), 'S-Docs', true);

        System.assertEquals(true, c.modelUsed, 'parsed from the (mocked) model response');
        System.assertEquals('S-Sign', c.product);
        System.assertEquals('troubleshooting', c.contentFormat);
        System.assertEquals('customer_safe', c.visibility);
        System.assertEquals('e_signature', c.topicArea);
    }

    @isTest
    static void liveBranchFallsToHeuristicOnUnparseableResponse() {
        HelpSdocsConnector.mockRawResponse = 'totally not json';
        HelpSdocsConnector.Classification c =
            HelpSdocsConnector.classify(page('<p>about S-Docs</p>'), 'S-Sign', true);
        System.assertEquals(false, c.modelUsed, 'unparseable -> heuristic');
        System.assertEquals('S-Docs', c.product, 'heuristic keyword detection');
    }

    @isTest
    static void mockSeamShortCircuits() {
        HelpSdocsConnector.Classification m = new HelpSdocsConnector.Classification();
        m.product = 'S-Sign';
        m.visibility = 'customer_safe';
        HelpSdocsConnector.mockResult = m;

        HelpSdocsConnector.Classification c =
            HelpSdocsConnector.classify(page('<p>anything</p>'), 'S-Docs', true);

        System.assertEquals('S-Sign', c.product, 'mock result is returned verbatim');
        System.assertEquals('customer_safe', c.visibility);
    }

    // ===================================================================================================
    // Sync service
    // ===================================================================================================

    private class SyncFakeTransport implements HelpSdocsConnector.Transport {
        public String get(String url) {
            if (url.endsWith('sitemap-pages.xml')) {
                return '<urlset>'
                    + '<url><loc>https://help.sdocs.com/seg/alpha</loc>'
                    + '<lastmod>2026-03-25T21:42:58.442Z</lastmod></url>'
                    + '<url><loc>https://help.sdocs.com/seg/beta</loc></url>'
                    + '</urlset>';
            }
            return '# Sample Page\n\nHow to configure a signature field. See the S-Sign guide.';
        }
    }

    private static HelpSdocsConnector.DocPage docPage(String id, String section) {
        HelpSdocsConnector.DocPage dp = new HelpSdocsConnector.DocPage();
        dp.id = id;
        dp.url = 'https://help.sdocs.com/' + id;
        dp.section = section;
        dp.title = 'Sample Page';
        dp.markdown = '# Sample Page\n\nHow to configure a signature field.';
        return dp;
    }

    @isTest
    static void dryRunPreviewsAreCustomerSafeAndWriteNothing() {
        HelpSdocsConnector.http = new SyncFakeTransport();
        HelpSdocsConnector.SyncOptions o = new HelpSdocsConnector.SyncOptions();
        o.sections = new List<String>{ 's-sign' };
        o.dryRun = true;

        Test.startTest();
        HelpSdocsConnector.SyncResult r = HelpSdocsConnector.run(o);
        Test.stopTest();

        System.assertEquals(2, r.pagesFetched);
        System.assertEquals(2, r.previews.size());
        System.assertEquals(0, r.processed, 'dry run writes nothing');
        System.assertEquals(0, [SELECT COUNT() FROM Support_Solution__c]);
        for (HelpSdocsConnector.Preview p : r.previews) {
            System.assertEquals('customer_safe', p.visibility, 'public docs default customer_safe');
            System.assertEquals('S-Sign', p.product, 's-sign section -> S-Sign');
        }
    }

    @isTest
    static void runSliceCommitsRecords() {
        HelpSdocsConnector.http = new SyncFakeTransport();
        List<HelpSdocsConnector.UrlRef> refs = new List<HelpSdocsConnector.UrlRef>{
            new HelpSdocsConnector.UrlRef('https://help.sdocs.com/sdocs/a', 'sdocs', null),
            new HelpSdocsConnector.UrlRef('https://help.sdocs.com/sdocs/b', 'sdocs', null)
        };
        HelpSdocsConnector.SyncOptions o = new HelpSdocsConnector.SyncOptions();
        o.sections = new List<String>{ 'sdocs' };

        Test.startTest();
        HelpSdocsConnector.SliceResult sr = HelpSdocsConnector.runSlice(o, refs, 0);
        Test.stopTest();

        System.assertEquals(2, sr.processed);
        System.assertEquals(-1, sr.nextOffset, 'all refs consumed -> done');
        List<Support_Solution__c> recs = [
            SELECT Confluence_Page_Id__c, Product__c, Visibility__c, Source_Space_Key__c, Active__c
            FROM Support_Solution__c ORDER BY Confluence_Page_Id__c];
        System.assertEquals(2, recs.size());
        System.assertEquals('sdocs/a', recs[0].Confluence_Page_Id__c);
        System.assertEquals('S-Docs', recs[0].Product__c);
        System.assertEquals('customer_safe', recs[0].Visibility__c);
        System.assertEquals('sdocs', recs[0].Source_Space_Key__c);
        System.assertEquals(true, recs[0].Active__c);
    }

    @isTest
    static void runSliceReturnsNextOffsetWhenMoreRemain() {
        HelpSdocsConnector.http = new SyncFakeTransport();
        // SLICE_SIZE is 40; 41 refs -> first slice processes 40 and points at offset 40.
        List<HelpSdocsConnector.UrlRef> refs = new List<HelpSdocsConnector.UrlRef>();
        for (Integer i = 0; i < 41; i++) {
            refs.add(new HelpSdocsConnector.UrlRef('https://help.sdocs.com/sdocs/p' + i, 'sdocs', null));
        }
        Test.startTest();
        HelpSdocsConnector.SliceResult sr =
            HelpSdocsConnector.runSlice(new HelpSdocsConnector.SyncOptions(), refs, 0);
        Test.stopTest();
        System.assertEquals(40, sr.nextOffset, 'window of 40 -> next offset 40');
        System.assertEquals(40, sr.processed);
    }

    @isTest
    static void classifiedFieldsFlowThroughAndVisibilityIsForced() {
        // Force a classification that PROPOSES agent_only - the service must still commit customer_safe.
        HelpSdocsConnector.Classification c = new HelpSdocsConnector.Classification();
        c.product = 'None';            // would normally block customer_safe; here it must not
        c.audience = 'agent';
        c.contentFormat = 'how_to';    // -> Solution_Type__c procedure
        c.sourceType = 'draft';
        c.topicArea = 'e_signature';
        c.topicDetail = 'pdf upload signing';
        c.visibility = 'agent_only';
        c.visibilityConfidence = 0.30;
        c.keywords = new List<String>{ 'pdf upload template', 'signature field placement', 'void request',
            'envelope recipient', 'advanced options tab', 'drag and drop', 'signer routing', 'e-signature setup' };
        HelpSdocsConnector.mockResult = c;

        SupportSolutionStore.PageInput pi =
            HelpSdocsConnector.toPageInput(docPage('s-sign/x', 's-sign'),
                new HelpSdocsConnector.SyncOptions());

        System.assertEquals('customer_safe', pi.visibility, 'forced safe regardless of classifier proposal');
        System.assertEquals('S-Sign', pi.product, 's-sign section overrides classifier product None');
        System.assertEquals('agent', pi.audience);
        System.assertEquals('e_signature', pi.topicArea);
        System.assertEquals('how_to', pi.contentFormat);
        System.assertEquals('procedure', pi.solutionType, 'derived from contentFormat how_to');
        System.assertEquals('draft', pi.sourceType);
        System.assert(pi.keywords.contains('pdf upload template'), 'model keywords flow to Keywords__c: ' + pi.keywords);
        System.assert(pi.keywords.split(', ').size() >= 8, 'has 8-10 keywords: ' + pi.keywords);
        HelpSdocsConnector.mockResult = null;
    }

    @isTest
    static void keywordsFallbackWhenModelReturnsFew() {
        // Sparse/heuristic classification (no model keywords) must still yield a populated keyword set.
        HelpSdocsConnector.Classification c = new HelpSdocsConnector.Classification();
        c.product = 'S-Sign';
        c.topicArea = 'e_signature';
        c.topicDetail = 'signer routing';
        c.keywords = new List<String>(); // model returned none
        HelpSdocsConnector.mockResult = c;

        SupportSolutionStore.PageInput pi =
            HelpSdocsConnector.toPageInput(docPage('s-sign/x', 's-sign'),
                new HelpSdocsConnector.SyncOptions());

        System.assert(String.isNotBlank(pi.keywords), 'fallback populated keywords: ' + pi.keywords);
        System.assert(pi.keywords.contains('signer routing'), 'topic detail used as fallback: ' + pi.keywords);
        HelpSdocsConnector.mockResult = null;
    }

    @isTest
    static void reconcileDeactivatesUntouchedRecords() {
        Support_Solution__c stale = new Support_Solution__c(
            Name = 'old', Confluence_Page_Id__c = 's-sign/old', Active__c = true,
            Source_Space_Key__c = 's-sign', Last_Synced__c = Datetime.now().addDays(-2));
        insert stale;

        HelpSdocsConnector.SyncOptions o = new HelpSdocsConnector.SyncOptions();
        o.sections = new List<String>{ 's-sign' };

        Test.startTest();
        Integer deactivated = HelpSdocsConnector.reconcileByTimestamp(o, Datetime.now());
        Test.stopTest();

        System.assertEquals(1, deactivated);
        System.assertEquals(false, [SELECT Active__c FROM Support_Solution__c WHERE Id = :stale.Id].Active__c);
    }

    // ===================================================================================================
    // Sync queueable
    // ===================================================================================================

    private class QueueFakeTransport implements HelpSdocsConnector.Transport {
        public String get(String url) {
            if (url.endsWith('sitemap-pages.xml')) {
                return '<urlset>'
                    + '<url><loc>https://help.sdocs.com/s-sign/one</loc></url>'
                    + '<url><loc>https://help.sdocs.com/s-sign/two</loc></url>'
                    + '</urlset>';
            }
            return '# Page\n\nHow to e-sign with S-Sign.';
        }
    }

    @isTest
    static void enqueueEnumeratesCommitsAndReconciles() {
        HelpSdocsConnector.http = new QueueFakeTransport();
        HelpSdocsConnector.SyncOptions o = new HelpSdocsConnector.SyncOptions();
        o.sections = new List<String>{ 's-sign' };

        Test.startTest();
        System.enqueueJob(new HelpSdocsConnector.HelpSdocsSyncQueueable(o));
        Test.stopTest();

        List<Support_Solution__c> recs = [
            SELECT Confluence_Page_Id__c, Visibility__c FROM Support_Solution__c ORDER BY Confluence_Page_Id__c];
        System.assertEquals(2, recs.size(), 'both enumerated pages committed');
        System.assertEquals('s-sign/one', recs[0].Confluence_Page_Id__c);
        System.assertEquals('customer_safe', recs[0].Visibility__c);
    }
}
