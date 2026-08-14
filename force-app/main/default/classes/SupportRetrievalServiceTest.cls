/**
 * SOSL is pinned via Test.setFixedSearchResults; embedding/distiller callouts are stubbed via seams.
 */
@isTest
private class SupportRetrievalServiceTest {

    private static Support_Solution__c sol(String pageId, String name, String body,
                                           String product, String source, String keywords) {
        return new Support_Solution__c(
            Name = name,
            Confluence_Page_Id__c = pageId,
            Body__c = body,
            Product__c = product,
            Source_Type__c = source,
            Keywords__c = keywords,
            Confluence_URL__c = 'https://example.atlassian.net/wiki/' + pageId,
            Active__c = true
        );
    }

    private static SupportRetrievalService.RetrievalInput input(String text, String product) {
        SupportRetrievalService.RetrievalInput inp = new SupportRetrievalService.RetrievalInput();
        inp.searchText = text;
        inp.product = product;
        return inp;
    }

    @isTest
    static void blankInputReturnsNone() {
        SupportRetrievalService.RetrievalResult r1 =
            SupportRetrievalService.retrieve(null);
        SupportRetrievalService.RetrievalResult r2 =
            SupportRetrievalService.retrieve(input('   ', 'S-Docs'));
        System.assertEquals('NONE', r1.confidence);
        System.assertEquals(false, r1.hasGoodMatch);
        System.assertEquals('NONE', r2.confidence);
        System.assertEquals(0, r2.candidates.size());
    }

    @isTest
    static void happyPathRanksAndScores() {
        List<Support_Solution__c> recs = new List<Support_Solution__c>{
            sol('P1', 'Merge fields not populating',
                'Merge fields render blank in the generated template document.', 'S-Docs', 'canned',
                'merge fields template blank'),
            sol('P2', 'Attach PDF to record',
                'Attach the generated pdf document back to the salesforce record.', 'S-Docs', 'tips',
                'attach pdf document record'),
            sol('P3', 'Unrelated networking note',
                'Configure the VPN tunnel and firewall ports.', 'S-Docs', 'unsorted',
                'vpn firewall network')
        };
        insert recs;

        Test.setFixedSearchResults(new List<Id>{ recs[0].Id, recs[1].Id, recs[2].Id });

        Test.startTest();
        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('merge fields blank template', 'S-Docs'));
        Test.stopTest();

        System.assert(!r.candidates.isEmpty(), 'Expected candidates');
        System.assertEquals('P1', r.candidates[0].confluencePageId,
            'Best lexical+trust match should rank first');
        System.assertEquals(1, r.tier, 'Tier 1 AND-search should have produced results');
        System.assertEquals('HIGH', r.confidence);
        System.assertEquals(true, r.hasGoodMatch);
        for (Integer i = 1; i < r.candidates.size(); i++) {
            System.assert(r.candidates[i - 1].score >= r.candidates[i].score,
                'Candidates must be sorted by score descending');
        }
    }

    @isTest
    static void noSosalHitsReturnsNoneFallback() {
        insert sol('X1', 'Anything', 'Some body text.', 'S-Docs', 'canned', 'x');
        Test.setFixedSearchResults(new List<Id>()); // SOSL returns empty

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('merge fields', 'S-Docs'));

        System.assertEquals('NONE', r.confidence);
        System.assertEquals(false, r.hasGoodMatch);
        System.assertEquals(0, r.candidates.size());
    }

    @isTest
    static void lowConfidenceWhenNothingMatchesText() {
        // Shares one of three terms -> weak-but-nonzero match -> LOW/MEDIUM.
        Support_Solution__c rec = sol('L1', 'Zzz', 'alpha qqq zzz yyy', 'S-Docs', 'unsorted', 'zzz');
        insert rec;
        Test.setFixedSearchResults(new List<Id>{ rec.Id });

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('alpha beta gamma', 'S-Docs'));

        System.assertEquals(false, r.hasGoodMatch);
        System.assert(r.confidence == 'LOW' || r.confidence == 'MEDIUM',
            'Weak match should be LOW/MEDIUM, was ' + r.confidence);
    }

    @isTest
    static void maxCandidatesCapsResults() {
        List<Support_Solution__c> recs = new List<Support_Solution__c>();
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 6; i++) {
            recs.add(sol('M' + i, 'Alpha ' + i, 'alpha content number ' + i, 'S-Docs', 'tips', 'alpha'));
        }
        insert recs;
        for (Support_Solution__c s : recs) { ids.add(s.Id); }
        Test.setFixedSearchResults(ids);

        SupportRetrievalService.RetrievalInput inp = input('alpha', 'S-Docs');
        inp.maxCandidates = 2;
        SupportRetrievalService.RetrievalResult r = SupportRetrievalService.retrieve(inp);

        System.assertEquals(2, r.candidates.size(), 'maxCandidates should cap the list');
    }

    @isTest
    static void draftTrustIsExcludedFromRetrieval() {
        // Unreviewed/internal trust tiers are filtered out by the RETURNING WHERE clause.
        Support_Solution__c wip =
            sol('DR1', 'WIP merge fields note', 'draft notes on widget merge fields not yet reviewed',
                'S-Docs', 'draft', 'widget merge fields');
        Support_Solution__c ops =
            sol('IO1', 'Ops runbook', 'internal ops process for widget merge fields escalation',
                'S-Docs', 'internal_ops', 'widget merge fields');
        insert new List<Support_Solution__c>{ wip, ops };
        Test.setFixedSearchResults(new List<Id>{ wip.Id, ops.Id });

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget merge fields', 'S-Docs'));

        System.assertEquals('NONE', r.confidence, 'draft/internal_ops must be excluded from drafting retrieval');
        System.assertEquals(0, r.candidates.size());
    }

    @isTest
    static void extractTermsCleansInput() {
        List<String> terms = SupportRetrievalService.extractTerms(
            'The S-Docs MERGE fields, merge merge!! to it');
        System.assert(terms.contains('docs'), 'Should keep meaningful tokens: ' + terms);
        System.assert(terms.contains('merge'));
        System.assert(terms.contains('fields'));
        System.assert(!terms.contains('the'), 'Stopwords dropped');
        System.assert(!terms.contains('to'), 'Short tokens dropped');
        // dedupe: 'merge' appears three times but only once in terms
        Integer mergeCount = 0;
        for (String t : terms) { if (t == 'merge') { mergeCount++; } }
        System.assertEquals(1, mergeCount, 'Terms should be de-duplicated');
    }

    @isTest
    static void stripBoilerplateRemovesNoise() {
        String raw = 'Generation fails with a Regex error. https://url.avanan.click/v2/r01/junk '
            + 'cid:image001.png contact me@corp.com\nFrom: Bob <bob@corp.com>\n'
            + 'This email message is confidential and intended only for the recipient; any '
            + 'unauthorized use is prohibited.';
        String cleaned = SupportRetrievalService.stripBoilerplate(raw);
        System.assert(cleaned.contains('Regex'), 'content kept: ' + cleaned);
        System.assert(!cleaned.contains('avanan'), 'URL stripped: ' + cleaned);
        System.assert(!cleaned.contains('image001'), 'cid ref stripped: ' + cleaned);
        System.assert(!cleaned.contains('From:'), 'forwarded header stripped: ' + cleaned);
        System.assert(!cleaned.contains('confidential'), 'legal disclaimer stripped: ' + cleaned);
    }

    @isTest
    static void stripBoilerplateDropsSignatureBlockKeepsQuotedThread() {
        String raw = 'The template save throws a validation error on the Amount field.\n'
            + 'Thanks,\nJane Rivera\nSenior RevOps Analyst\nAcme Corp\n\n'
            + 'The quoted earlier email below still has real content about the lineitems table '
            + 'not rendering when the related list query returns no rows for the account record.';
        String cleaned = SupportRetrievalService.stripBoilerplate(raw);
        System.assert(cleaned.contains('validation error'), 'content kept: ' + cleaned);
        System.assert(!cleaned.contains('Rivera'), 'signature name dropped: ' + cleaned);
        System.assert(!cleaned.contains('RevOps'), 'signature title dropped: ' + cleaned);
        System.assert(cleaned.contains('lineitems'), 'quoted-thread content survives: ' + cleaned);
    }

    @isTest
    static void extractTermsHonorsQueryTermCap() {
        // The prose path previously broke at a stale hardcoded 10; it must fill the full 12-term cap.
        List<String> terms = SupportRetrievalService.extractTerms(
            'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november');
        System.assertEquals(12, terms.size(), 'prose path fills QUERY_TERM_CAP: ' + terms);
    }

    @isTest
    static void buildQueryTermsPrependsHighSignal() {
        // A verbatim quoted error + a code identifier that sit deep in the text still reach the query,
        // ahead of the leading prose, so a buried-error case can pool + score its answering doc.
        String text = 'Customer has access and I do not know the answer here. The long legacy account '
            + 'hits an error when generating: "Regex too complicated" thrown from SDCreate3.';
        List<String> terms = SupportRetrievalService.buildQueryTerms(text);
        System.assert(terms.contains('regex'), 'quoted error token present: ' + terms);
        System.assert(terms.contains('complicated'), 'quoted error token present: ' + terms);
        System.assert(terms.contains('sdcreate3'), 'code identifier present: ' + terms);
        System.assert(terms.size() <= 12, 'query breadth capped: ' + terms);
    }

    @isTest
    static void confidenceIsDecoupledFromTier() {
        // A strong content match reaches HIGH regardless of which tier surfaced it.
        Support_Solution__c perfect = sol('B1', 'Sigmaflux calibration guide',
            'Full walkthrough to calibrate the sigmaflux and recharge the zorptmeter device.',
            'S-Docs', 'canned', 'sigmaflux zorptmeter calibrate');
        Support_Solution__c decoy = sol('B2', 'Sigmaflux overview',
            'A short note that mentions sigmaflux only.', 'S-Docs', 'unsorted', 'sigmaflux');
        insert new List<Support_Solution__c>{ perfect, decoy };

        Test.setFixedSearchResults(new List<Id>{ perfect.Id, decoy.Id });
        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('sigmaflux zorptmeter calibrate', 'S-Docs'));

        System.assertEquals('B1', r.candidates[0].confluencePageId, 'Best content match ranks first');
        System.assertEquals('HIGH', r.confidence, 'A strong match must reach HIGH regardless of tier');
        System.assert(r.candidates[0].score >= 0.45,
            'Perfect broad-path match must clear the HIGH bar on its own merits, was '
                + r.candidates[0].score);
        // The weak partial match (B2) is legitimately below the adaptive relative-floor, so selection
        // may drop it. If it survives, it must score strictly below the perfect match (no 1.0 tie).
        if (r.candidates.size() > 1) {
            System.assert(r.candidates[0].score > r.candidates[1].score,
                'Continuous scoring must separate the perfect match from the partial one');
        }
    }

    @isTest
    static void continuousScoringBreaksFullCoverageTies() {
        // Five docs that ALL contain every query term -> the OLD model collapsed them to a single 1.0
        // rung. The new model must SEPARATE them on field placement / phrase / frequency / trust.
        List<Support_Solution__c> recs = new List<Support_Solution__c>{
            // strongest: terms in the title AS A PHRASE + keywords + canned
            sol('T1', 'Merge fields blank in template',
                'Merge fields are blank in the generated template document; fix the merge mapping.',
                'S-Docs', 'canned', 'merge fields blank template'),
            // body-only, scattered, lower trust
            sol('T2', 'General notes',
                'Sometimes a field is blank. The template may merge. Various fields exist here.',
                'S-Docs', 'unsorted', 'notes'),
            // title partial + body, tips
            sol('T3', 'Template formatting',
                'The template can show blank merge fields when mapping is wrong.',
                'S-Docs', 'tips', 'template'),
            // keywords carry the terms, body thin
            sol('T4', 'Mapping help',
                'See mapping. blank template merge fields.',
                'S-Docs', 'unsorted', 'merge fields blank template mapping'),
            // weakest real match: each term once, far apart, draft trust
            sol('T5', 'Misc',
                'merge ... fields ... blank ... template ... appear somewhere in this long note.',
                'S-Docs', 'draft', 'misc')
        };
        insert recs;
        List<Id> ids = new List<Id>();
        for (Support_Solution__c s : recs) { ids.add(s.Id); }
        Test.setFixedSearchResults(ids);

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('merge fields blank template', 'S-Docs'));

        // No two scores may collapse to the same rung (the old failure): all distinct.
        Set<Decimal> distinct = new Set<Decimal>();
        for (SupportRetrievalService.Candidate c : r.candidates) { distinct.add(c.score); }
        System.assertEquals(r.candidates.size(), distinct.size(),
            'Full-coverage docs must get distinct continuous scores, not one shared rung');
        // The title-phrase + canned doc must win.
        System.assertEquals('T1', r.candidates[0].confluencePageId, 'Phrase-in-title + canned should lead');
        // Explainability breakdown must be populated.
        System.assertNotEquals(null, r.candidates[0].breakdown, 'Per-signal breakdown must be emitted');
        System.assert(r.candidates[0].breakdown.content > 0, 'content should be set');
    }

    // ---- semantic (embedding cosine) blend ----

    /** Stub embedding client: returns a fixed query vector, never calls out. */
    private class StubEmbedClient implements SupportRetrievalService.EmbeddingClient {
        List<Double> queryVec;
        StubEmbedClient(List<Double> v) { this.queryVec = v; }
        public List<List<Double>> embed(String modelName, List<String> texts) {
            List<List<Double>> out = new List<List<Double>>();
            for (Integer i = 0; i < texts.size(); i++) { out.add(queryVec); }
            return out;
        }
    }

    @isTest
    static void semanticBlendSeparatesLexicallyEqualDocs() {
        // Two docs with IDENTICAL lexical content (same term, same fields) -> equal lexical score. Only the
        // stored embedding differs: D1's vector aligns with the query, D2's is orthogonal. The semantic
        // blend must therefore rank D1 above D2 - the core of #1 (semantic relevance, not vocabulary).
        Support_Solution__c d1 = sol('V1', 'Widget help', 'the widget here', 'S-Docs', 'unsorted', 'widget');
        Support_Solution__c d2 = sol('V2', 'Widget help', 'the widget here', 'S-Docs', 'unsorted', 'widget');
        d1.Embedding__c = '[1, 0]';   // aligns with the query vector below -> cosine 1
        d2.Embedding__c = '[0, 1]';   // orthogonal -> cosine 0
        insert new List<Support_Solution__c>{ d1, d2 };
        Test.setFixedSearchResults(new List<Id>{ d1.Id, d2.Id });

        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget', 'S-Docs'));

        // The aligned doc ranks first and carries a full semantic signal. The orthogonal-vector doc is
        // legitimately weaker; adaptive selection may drop it entirely (the point: semantic relevance, on
        // top of identical lexical content, decides the outcome). If it survives, it must rank strictly below.
        System.assertEquals('V1', r.candidates[0].confluencePageId, 'Semantically-aligned doc must rank first');
        System.assertEquals(1, r.candidates[0].breakdown.semanticRaw, 'D1 raw cosine should be 1');
        System.assert(r.candidates[0].breakdown.semantic > 0.99, 'D1 rescaled semantic should be ~1');
        if (r.candidates.size() > 1) {
            System.assert(r.candidates[0].score > r.candidates[1].score, 'Semantic must separate them');
            System.assert(r.candidates[1].breakdown.semantic < r.candidates[0].breakdown.semantic,
                'The orthogonal doc must carry a weaker semantic signal');
        }
    }

    @isTest
    static void semanticFallsBackToLexicalWhenVectorMissingOrQueryEmbedFails() {
        // With embeddings on and the query embed succeeding, a doc with NO stored vector must still
        // retrieve on pure lexical (semantic = -1 N/A) — the blend never breaks the lexical path.
        Support_Solution__c d1 = sol('N1', 'Widget alpha', 'widget alpha alpha', 'S-Docs', 'canned', 'widget alpha');
        insert new List<Support_Solution__c>{ d1 };
        Test.setFixedSearchResults(new List<Id>{ d1.Id });

        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget alpha', 'S-Docs'));

        System.assertEquals('N1', r.candidates[0].confluencePageId, 'No-vector doc still retrieves');
        System.assertEquals(-1, r.candidates[0].breakdown.semantic, 'No vector -> semantic N/A (pure lexical)');
        System.assert(r.candidates[0].breakdown.content > 0, 'Content falls back to the lexical signal');
    }

    @isTest
    static void selectAdaptiveRespectsCeilingAndCluster() {
        // Direct unit test of the selection policy on a synthetic, already-sorted candidate list.
        List<SupportRetrievalService.Candidate> sorted = new List<SupportRetrievalService.Candidate>();
        for (Decimal sc : new List<Decimal>{ 0.90, 0.88, 0.86, 0.85, 0.84, 0.83 }) {
            SupportRetrievalService.Candidate c = new SupportRetrievalService.Candidate();
            c.score = sc;
            sorted.add(c);
        }
        SupportRetrievalService.Config cfg = new SupportRetrievalService.Config();
        // Tight cluster, no big gap -> only the context budget (ceiling) limits inclusion.
        List<SupportRetrievalService.Candidate> kept =
            SupportRetrievalService.selectAdaptive(sorted, cfg, 3);
        System.assertEquals(3, kept.size(), 'Ceiling caps a gap-free cluster');

        // Now introduce a steep gap after the 2nd doc -> selection stops at the cluster boundary.
        sorted[2].score = 0.40; sorted[3].score = 0.39; sorted[4].score = 0.38; sorted[5].score = 0.37;
        List<SupportRetrievalService.Candidate> kept2 =
            SupportRetrievalService.selectAdaptive(sorted, cfg, 5);
        System.assertEquals(2, kept2.size(), 'Selection stops at the natural gap before the weak tail');
    }

    // ---- RRF fusion + common-case priority (gate-then-weight) ----

    private static Support_Solution__c commonCase(String pageId, String name, String body,
                                                  String keywords, String embedding) {
        Support_Solution__c s = sol(pageId, name, body, 'S-Docs', 'official', keywords);
        s.Common_Case__c = true;
        s.Embedding__c = embedding;
        return s;
    }

    @isTest
    static void rrfPriorityLiftsAdmittedCommonCase() {
        // d2 (non-common) and cc (common) are a genuine near-tie; priority must break it in cc's favour,
        // and with priority off it must not. (Overriding a materially stronger doc is forbidden — see
        // rrfPriorityGuardBlocksLeapfrog.)
        Support_Solution__c d2 = sol('D2', 'widget config help',
            'widget config settings', 'S-Docs', 'official', 'widget config');
        d2.Embedding__c = '[1, 0]';
        Support_Solution__c cc = commonCase('CC1', 'widget config note', 'widget config settings',
            'widget config', '[1, 0]');
        insert new List<Support_Solution__c>{ d2, cc };
        Test.setFixedSearchResults(new List<Id>{ d2.Id, cc.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;

        // priority OFF
        SupportRetrievalService.testForcePriorityEnabled = false;
        SupportRetrievalService.RetrievalResult noPrio =
            SupportRetrievalService.retrieve(input('widget config', 'S-Docs'));
        System.assertEquals('D2', noPrio.candidates[0].confluencePageId,
            'Without priority the non-common doc leads the near-tie');

        // priority ON
        SupportRetrievalService.testForcePriorityEnabled = true;
        SupportRetrievalService.RetrievalResult prio =
            SupportRetrievalService.retrieve(input('widget config', 'S-Docs'));
        System.assertEquals('CC1', prio.candidates[0].confluencePageId,
            'Gated priority must break the near-tie in favour of the admitted common case');
    }

    @isTest
    static void rrfPriorityGuardBlocksLeapfrog() {
        // No-leapfrog: a common case that clears the gate but is a MATERIALLY weaker match than a
        // non-common doc must not be boosted over it.
        Support_Solution__c d2 = sol('D2', 'widget config help',
            'widget config configuration settings page adjust options', 'S-Docs', 'official', 'widget config settings');
        d2.Embedding__c = '[1, 0]';
        Support_Solution__c cc = commonCase('CC1', 'widget note', 'widget', 'widget', '[1, 0]');
        insert new List<Support_Solution__c>{ d2, cc };
        Test.setFixedSearchResults(new List<Id>{ d2.Id, cc.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;
        SupportRetrievalService.testForcePriorityEnabled = true;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget config', 'S-Docs'));
        System.assertEquals('D2', r.candidates[0].confluencePageId,
            'No-leapfrog guard: a materially weaker common case must not override the stronger answer');
    }

    @isTest
    static void rrfPriorityGateBlocksWeakCommonCase() {
        // cc fails the gate on both axes (orthogonal embedding, no matching term): no boost may apply.
        Support_Solution__c strong = sol('GZ', 'widget gizmo guide',
            'widget gizmo configuration walkthrough', 'S-Docs', 'official', 'widget gizmo');
        strong.Embedding__c = '[1, 0]';
        Support_Solution__c cc = commonCase('CC2', 'misc note', 'something else entirely', 'misc', '[0, 1]');
        insert new List<Support_Solution__c>{ strong, cc };
        Test.setFixedSearchResults(new List<Id>{ strong.Id, cc.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;
        SupportRetrievalService.testForcePriorityEnabled = true;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget gizmo', 'S-Docs'));

        System.assertEquals('GZ', r.candidates[0].confluencePageId, 'The genuine match must still win');
        if (r.candidates.size() > 1) {
            System.assert(r.candidates[1].score < r.candidates[0].score,
                'The un-boosted common case must not tie the genuine match');
        }
    }

    @isTest
    static void rrfPriorityRespectsMaxPromotions() {
        // Three near-duplicate common cases all clear the gate. With the cap at 1, exactly ONE is
        // boosted (to the normalized top at 1.0); the un-boosted near-duplicates score ~half and fall
        // below the adaptive relative floor, so the common-case set can't flood the top.
        Support_Solution__c c1 = commonCase('K1', 'widget error one', 'widget error fix one', 'widget error', '[1, 0]');
        Support_Solution__c c2 = commonCase('K2', 'widget error two', 'widget error fix two', 'widget error', '[1, 0]');
        Support_Solution__c c3 = commonCase('K3', 'widget error three', 'widget error fix three', 'widget error', '[1, 0]');
        insert new List<Support_Solution__c>{ c1, c2, c3 };
        Test.setFixedSearchResults(new List<Id>{ c1.Id, c2.Id, c3.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;
        SupportRetrievalService.testForcePriorityEnabled = true;
        SupportRetrievalService.testForcePriorityMaxPromo = 1;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('widget error', 'S-Docs'));

        System.assertEquals(1.0, r.candidates[0].score.doubleValue(),
            'Exactly one boosted case sits at the normalized top');
        for (Integer i = 1; i < r.candidates.size(); i++) {
            System.assert(r.candidates[i].score < 0.6,
                'Un-boosted near-duplicates score ~half the boosted one, was ' + r.candidates[i].score);
        }
    }

    // ---- resilient retrieval: query distillation + lexical-floor blend ----

    /** Stub distiller: returns a fixed query (or throws / returns '' to exercise the fallbacks). */
    private class StubDistiller implements SupportRetrievalService.QueryDistiller {
        String query;
        Boolean throwIt = false;
        Boolean called = false;
        StubDistiller(String q) { this.query = q; }
        public String distill(String modelName, String caseText) {
            called = true;
            if (throwIt) { throw new CalloutException('stub distiller down'); }
            return query;
        }
    }

    @isTest
    static void resilientDistillsWhenFirstPassWeak() {
        // Same pinned pool for both passes (setFixedSearchResults pins ALL SOSL); only the QUERY changes.
        // Pass 1 query 'alpha' matches nothing in the pool -> topScore 0 (< trigger 0.45) -> distill fires.
        // The distiller rewrites to 'beta', which the target doc matches strongly -> distilled pass wins.
        Support_Solution__c target = sol('DQ1', 'beta workflow', 'beta beta beta configuration', 'S-Docs', 'official', 'beta');
        insert new List<Support_Solution__c>{ target };
        Test.setFixedSearchResults(new List<Id>{ target.Id });

        SupportRetrievalService.testForceQueryDistill = true;
        StubDistiller sd = new StubDistiller('beta');
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('alpha', 'S-Docs'));

        System.assertEquals(true, sd.called, 'A weak first pass must trigger distillation');
        System.assertEquals(true, r.distilled, 'The distilled pass produced the stronger result');
        System.assertEquals('beta', r.distilledQuery, 'The distilled query is recorded');
        System.assertEquals('DQ1', r.candidates[0].confluencePageId, 'The distilled query surfaces the target doc');
        System.assert(r.topScore > 0, 'The distilled pass has a real score');
    }

    @isTest
    static void resilientSkipsDistillWhenFirstPassStrong() {
        // Pass 1 already clears the trigger -> no callout is made and the first result is returned as-is.
        Support_Solution__c strong = sol('DQ2', 'beta', 'beta beta beta', 'S-Docs', 'official', 'beta');
        insert new List<Support_Solution__c>{ strong };
        Test.setFixedSearchResults(new List<Id>{ strong.Id });

        SupportRetrievalService.testForceQueryDistill = true;
        StubDistiller sd = new StubDistiller('should-not-run');
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('beta', 'S-Docs'));

        System.assert(r.topScore >= 0.45, 'Precondition: the first pass is strong');
        System.assertEquals(false, sd.called, 'A strong first pass must NOT spend a distillation call');
        System.assertEquals(false, r.distilled, 'No distilled pass ran');
        System.assertEquals(null, r.distilledQuery, 'No distilled query recorded');
    }

    @isTest
    static void resilientFallsBackWhenDistillerFails() {
        // Weak first pass, but the distiller throws -> we keep the (weak) first pass rather than hard-failing.
        Support_Solution__c d = sol('DQ3', 'beta', 'beta beta', 'S-Docs', 'official', 'beta');
        insert new List<Support_Solution__c>{ d };
        Test.setFixedSearchResults(new List<Id>{ d.Id });

        SupportRetrievalService.testForceQueryDistill = true;
        StubDistiller sd = new StubDistiller(null);
        sd.throwIt = true;
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('alpha', 'S-Docs'));

        System.assertEquals(true, sd.called, 'Distillation was attempted');
        System.assertEquals(false, r.distilled, 'A distiller failure must fall back to the first pass');
    }

    @isTest
    static void resilientDisabledEqualsPlainRetrieve() {
        // With distillation off, retrieveResilient must never call out and must equal retrieve()'s outcome.
        Support_Solution__c d = sol('DQ4', 'gamma', 'gamma gamma', 'S-Docs', 'official', 'gamma');
        insert new List<Support_Solution__c>{ d };
        Test.setFixedSearchResults(new List<Id>{ d.Id });

        SupportRetrievalService.testForceQueryDistill = false;
        StubDistiller sd = new StubDistiller('beta');
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('alpha', 'S-Docs')); // weak, but distill disabled

        System.assertEquals(false, sd.called, 'Disabled distillation must not call out');
        System.assertEquals(false, r.distilled, 'No distilled pass when disabled');
    }

    @isTest
    static void resilientMarginRejectsMarginalDistilledWin() {
        // The distiller output is SAMPLED (no temperature control on the wrapper), so a distilled pass that
        // beats the deterministic first pass by less than the accept margin is indistinguishable from
        // sampling noise: it must be discarded (first pass kept, tried query still recorded). Here the
        // distilled pass genuinely scores higher, but the forced margin makes the win non-decisive.
        Support_Solution__c target = sol('DQ5', 'beta workflow', 'beta beta beta configuration', 'S-Docs', 'official', 'beta');
        insert new List<Support_Solution__c>{ target };
        Test.setFixedSearchResults(new List<Id>{ target.Id });

        SupportRetrievalService.testForceQueryDistill = true;
        SupportRetrievalService.testForceDistillAcceptMargin = 999; // nothing can be "decisive"
        StubDistiller sd = new StubDistiller('beta');
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('alpha', 'S-Docs'));

        System.assertEquals(true, sd.called, 'The weak first pass still triggers distillation');
        System.assertEquals(false, r.distilled,
            'A non-decisive distilled win must NOT replace the deterministic first pass');
        System.assertEquals('beta', r.distilledQuery, 'The tried query is still recorded for the audit trail');
        System.assertEquals(0, r.topScore, 'The first-pass score (the stable baseline) is what is returned');
    }

    @isTest
    static void resilientRejectsSubFloorDistilledImprovement() {
        // The distilled pass IS better than the first pass but still below draftable strength (the distill
        // trigger / draft floor): switching to it would change no routing outcome - it would only inject a
        // sampled (non-reproducible) score into the audit fields - so the deterministic first pass is kept.
        Support_Solution__c target = sol('DQ6', 'beta workflow', 'beta beta beta configuration', 'S-Docs', 'official', 'beta');
        insert new List<Support_Solution__c>{ target };
        Test.setFixedSearchResults(new List<Id>{ target.Id });

        SupportRetrievalService.testForceQueryDistill = true;
        SupportRetrievalService.testForceDistillAcceptMargin = 0.0; // isolate the floor bar from the margin bar
        StubDistiller sd = new StubDistiller('beta gamma'); // half-matching rewrite -> real but sub-floor score
        SupportRetrievalService.distiller = sd;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieveResilient(input('alpha', 'S-Docs'));

        System.assertEquals(false, r.distilled,
            'A sub-floor distilled improvement must not replace the deterministic baseline');
        System.assertEquals('beta gamma', r.distilledQuery, 'The tried query is still recorded');
        System.assertEquals(0, r.topScore, 'The stable first-pass score is what is returned');
    }

    // ---- multi-product filter + content-max topScore ----

    @isTest
    static void splitProductsHandlesMultiSelectValues() {
        System.assertEquals(null, SupportRetrievalService.splitProducts(null), 'null -> no filter');
        System.assertEquals(null, SupportRetrievalService.splitProducts('  '), 'blank -> no filter');
        System.assertEquals(null, SupportRetrievalService.splitProducts(';;'), 'separator-only -> no filter');
        System.assertEquals(new List<String>{ 'S-Docs' },
            SupportRetrievalService.splitProducts(' S-Docs '), 'single value trimmed');
        System.assertEquals(new List<String>{ 'S-Docs', 'S-Sign' },
            SupportRetrievalService.splitProducts('S-Docs;S-Sign'), 'multi-select splits on ;');
        System.assertEquals(new List<String>{ 'S-Docs', 'S-Sign' },
            SupportRetrievalService.splitProducts(' S-Docs ; S-Sign ;'), 'tokens trimmed, blanks dropped');
    }

    @isTest
    static void multiProductValueSearchesBothProducts() {
        // A multi-select Product_List__c value ('S-Docs;S-Sign') used to be bound verbatim to
        // Product__c = :product, matching NOTHING (7/100 eval cases hard-zeroed). Each token must
        // now filter independently. Fixed search results are still subject to the RETURNING WHERE
        // clause, so the product filter is exercised for real here.
        Support_Solution__c docsDoc = sol('MP1', 'widget signing guide',
            'widget signing walkthrough for the generated document.', 'S-Docs', 'canned', 'widget signing');
        Support_Solution__c signDoc = sol('MP2', 'widget signing guide',
            'widget signing walkthrough for the generated document.', 'S-Sign', 'canned', 'widget signing');
        insert new List<Support_Solution__c>{ docsDoc, signDoc };
        Test.setFixedSearchResults(new List<Id>{ docsDoc.Id, signDoc.Id });

        SupportRetrievalService.RetrievalResult both =
            SupportRetrievalService.retrieve(input('widget signing', 'S-Docs;S-Sign'));
        Set<String> pages = new Set<String>();
        for (SupportRetrievalService.Candidate c : both.candidates) { pages.add(c.confluencePageId); }
        System.assert(pages.contains('MP1') && pages.contains('MP2'),
            'Multi-product value must retrieve docs of BOTH products, got ' + pages);

        SupportRetrievalService.RetrievalResult one =
            SupportRetrievalService.retrieve(input('widget signing', 'S-Sign'));
        for (SupportRetrievalService.Candidate c : one.candidates) {
            System.assertEquals('S-Sign', c.product, 'Single-product input must still filter');
        }
        System.assert(!one.candidates.isEmpty(), 'The matching product still retrieves');
    }

    @isTest
    static void topScoreIsContentMaxAcrossCandidates() {
        // RRF ranks on reciprocal lexical+semantic rank, so the strongest CONTENT evidence can sit
        // below rank 1; topScore/confidence must read the max across the fed set, not rank 1 alone.
        SupportRetrievalService.Candidate rank1 = new SupportRetrievalService.Candidate();
        rank1.score = 1.0; // fused rank-based score (normalized top)
        rank1.breakdown = new SupportRetrievalService.ScoreBreakdown();
        rank1.breakdown.content = 0.30;
        SupportRetrievalService.Candidate rank2 = new SupportRetrievalService.Candidate();
        rank2.score = 0.9;
        rank2.breakdown = new SupportRetrievalService.ScoreBreakdown();
        rank2.breakdown.content = 0.70;
        SupportRetrievalService.Candidate rank3 = new SupportRetrievalService.Candidate();
        rank3.score = 0.8; // no breakdown -> falls back to the fused score, must not win over real content
        System.assertEquals(0.80,
            SupportRetrievalService.contentMax(new List<SupportRetrievalService.Candidate>{ rank1, rank2, rank3 }),
            'contentMax takes the strongest signal (breakdown.content, else score) across ALL candidates');
        System.assertEquals(0.70,
            SupportRetrievalService.contentMax(new List<SupportRetrievalService.Candidate>{ rank1, rank2 }),
            'A rank-2 doc with stronger content outranks the RRF rank-1 read');
        System.assertEquals(null,
            SupportRetrievalService.contentMax(new List<SupportRetrievalService.Candidate>()),
            'Empty fed set -> null (caller falls back to NONE)');
    }

    @isTest
    static void topScoreReadsStrongestContentThroughRetrieve() {
        // End-to-end wiring check: two docs where the semantically-led RRF winner carries WEAKER
        // content than the lexical doc behind it. topScore must come from the stronger content.
        Support_Solution__c semDoc = sol('CM1', 'note', 'gizmo note', 'S-Docs', 'canned', 'gizmo');
        semDoc.Embedding__c = '[1, 0]';   // cosine 1 -> leads the dense channel
        Support_Solution__c lexDoc = sol('CM2', 'gizmo calibration walkthrough',
            'gizmo calibration walkthrough to calibrate the gizmo calibration module.',
            'S-Docs', 'tips', 'gizmo calibration walkthrough');
        lexDoc.Embedding__c = '[0.8, 0.6]'; // cosine 0.8 -> real but weaker dense signal
        insert new List<Support_Solution__c>{ semDoc, lexDoc };
        Test.setFixedSearchResults(new List<Id>{ semDoc.Id, lexDoc.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;

        SupportRetrievalService.RetrievalResult r =
            SupportRetrievalService.retrieve(input('gizmo calibration walkthrough', 'S-Docs'));

        Double maxContent;
        for (SupportRetrievalService.Candidate c : r.candidates) {
            if (maxContent == null || c.breakdown.content > maxContent) { maxContent = c.breakdown.content; }
        }
        System.assertEquals(
            Decimal.valueOf(maxContent).setScale(4, System.RoundingMode.HALF_UP), r.topScore,
            'topScore must equal the strongest content across the fed set, whatever the RRF order');
    }

    @isTest
    static void lexicalFloorLiftsStrongLexicalWeakSemanticDoc() {
        // A doc with a strong lexical match but an orthogonal (noise-floor) embedding: the semantic-led blend
        // drags its content to (1-w)*lexical. The lexical floor (frac 0.75 > 1-w=0.45) must lift it back to
        // frac*lexical, so a cross-vocabulary match is not sunk by a dead embedding. A high-semantic doc is
        // unaffected. We compare the SAME doc's content with the floor off vs on.
        Support_Solution__c d = sol('LF1', 'widget widget', 'widget widget widget', 'S-Docs', 'official', 'widget');
        d.Embedding__c = '[0, 1]'; // orthogonal to the query vector below -> cosine 0 -> semantic 0
        insert new List<Support_Solution__c>{ d };
        Test.setFixedSearchResults(new List<Id>{ d.Id });
        SupportRetrievalService.embedClient = new StubEmbedClient(new List<Double>{ 1, 0 });
        SupportRetrievalService.testForceEmbedding = true;

        SupportRetrievalService.testForceLexicalFloorFrac = 0.0;
        Double contentOff = SupportRetrievalService.retrieve(input('widget', 'S-Docs'))
            .candidates[0].breakdown.content;
        Double lexOff = SupportRetrievalService.retrieve(input('widget', 'S-Docs'))
            .candidates[0].breakdown.lexical;

        SupportRetrievalService.testForceLexicalFloorFrac = 0.75;
        SupportRetrievalService.Candidate withFloor =
            SupportRetrievalService.retrieve(input('widget', 'S-Docs')).candidates[0];

        System.assert(withFloor.breakdown.semantic <= 0.0001, 'Precondition: semantic is at the noise floor');
        System.assert(withFloor.breakdown.content > contentOff,
            'The lexical floor must lift a strong-lexical / dead-semantic doc (' + withFloor.breakdown.content
            + ' vs ' + contentOff + ')');
        System.assert(Math.abs(withFloor.breakdown.content - 0.75 * lexOff) < 0.0005,
            'Floored content should equal frac * lexical when semantic is 0');
    }

    // ---- verbatim error-string pooling channel ----

    @isTest
    static void unionByIdDedupesAndPreservesPrimaryOrder() {
        Support_Solution__c a = sol('U1', 'Alpha', 'alpha body', 'S-Docs', 'official', 'alpha');
        Support_Solution__c b = sol('U2', 'Beta', 'beta body', 'S-Docs', 'official', 'beta');
        Support_Solution__c c = sol('U3', 'Gamma', 'gamma body', 'S-Docs', 'official', 'gamma');
        insert new List<Support_Solution__c>{ a, b, c };

        List<Support_Solution__c> merged = SupportRetrievalService.unionById(
            new List<Support_Solution__c>{ a, b },
            new List<Support_Solution__c>{ b, c }); // b overlaps; c is the channel addition

        System.assertEquals(3, merged.size(), 'Overlap deduped, addition kept');
        System.assertEquals(a.Id, merged[0].Id, 'Primary pool order preserved');
        System.assertEquals(b.Id, merged[1].Id, 'Duplicate kept from the primary pool, not re-added');
        System.assertEquals(c.Id, merged[2].Id, 'Channel additions appended after the primary pool');

        System.assertEquals(2, SupportRetrievalService.unionById(
            new List<Support_Solution__c>{ a, b }, new List<Support_Solution__c>()).size(),
            'Empty channel is a no-op');
        System.assertEquals(1, SupportRetrievalService.unionById(
            new List<Support_Solution__c>(), new List<Support_Solution__c>{ c }).size(),
            'Empty primary pool takes the channel results');
    }
}
