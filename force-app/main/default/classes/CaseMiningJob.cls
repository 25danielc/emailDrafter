/**
 * Corpus mining: turns historical closed Email cases (what customers actually asked + what agents
 * actually answered) into customer_safe Support_Solution__c docs, closing the corpus-gap bucket the
 * 2026-07-16 decline diagnosis measured at ~39% of declines.
 *
 * Chained Queueable state machine (DraftEvalBatchJob pattern), three phases:
 *   HARVEST  (5 cases/link, 1 LLM callout each): per closed case with >=1 substantive outbound
 *            agent reply, extract {question, resolution, error strings}; the prompt requires the
 *            resolution to be a condensation of the AGENT'S OWN WORDS — no fix in the replies means
 *            the case is dropped (substantive=false). Junk/billing (CaseIntakeClassifier) never enter.
 *   CLUSTER  (single link): embed question summaries (batched), greedy leader clustering; seed
 *            topics (the diagnosis doc backlog) claim their matching cases first. A seed with zero
 *            harvested cases produces NO doc (nothing to ground in) and is flagged for a human.
 *   GENERATE (3 clusters/link): per cluster, (a) generate a doc grounded ONLY in the member cases'
 *            full agent replies, (b) dedupe-gate via deterministic retrieve() — skip if the
 *            existing non-mined corpus already answers at the draft floor, (c) adversarial verify
 *            call — reject claims unsupported by the source replies, (d) mechanical gates (size,
 *            Resolution section, PII/URL scrub), (e) upsert via SupportSolutionStore.upsertPages
 *            with sourceSpaceKey='case-mined' (survives help.sdocs reconcile; one-command rollback)
 *            + provenance stamp (Mined_From_Cases__c).
 *
 * Docs land ACTIVE and customer_safe (auto-ingest per project decision) at sourceType 'tribal' —
 * the honest trust tier for agent-reply-derived content. Rollback: scripts/apex/rollback_case_mined.apex.
 * Embedding backfill (SupportSolutionStore.enqueue) is chained after the final link.
 * Kick off via scripts/apex/run_case_mining.apex.
 */
public with sharing class CaseMiningJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static Integer HARVEST_CHUNK = 5;   // 1 LLM callout per case
    // ONE cluster per link: an ACCEPTED cluster ends in DML (upsert + provenance stamp), and
    // Salesforce forbids callouts after DML in the same transaction — a 3-cluster chunk poisoned
    // the 2nd/3rd cluster's generate/verify callouts whenever an earlier one accepted
    // (CalloutException 'pending uncommitted changes', seen on the 2026-07-21 import run).
    @TestVisible private static Integer GENERATE_CHUNK = 1;
    private static final Integer MAX_DEPTH = 250;            // backstop across all phases (815-case
                                                             // 07-22 import = ~163 harvest links)
    private static final Integer MIN_REPLY_CHARS = 200;      // below this an outbound reply is noise
    private static final Integer REPLY_CAP_PER_CASE = 3000;  // grounding-context cap per case
    private static final Integer REPLY_HEAD_KEEP = 600;      // opening kept when the cap trims the middle
    private static final Integer GROUNDING_CASES_MAX = 5;    // strongest N members ground the doc
    private static final Integer QUESTION_MAX = 300;
    private static final Integer RESOLUTION_MAX = 800;
    @TestVisible private static Double CLUSTER_JOIN_COSINE = 0.80;
    private static final Integer EMBED_BATCH = 16;
    private static final Integer BODY_MIN_CHARS = 200;       // 300 rejected a complete 209-char capability doc (07-21b hubspot cluster)
    private static final Integer BODY_MAX_CHARS = 4000;
    // Dedupe skip bar. The draft floor (0.45) is too loose here: the 07-21b run killed 8 clusters on
    // 0.47-0.60 matches while the 2026-07-22 decline labeling proved 19 corpus gaps remained. Only a
    // STRONG existing answer should suppress generation; borderline matches proceed and still face
    // the adversarial verify + gates.
    @TestVisible private static Double DEDUPE_SKIP_SCORE = 0.60;
    public static final String SPACE_KEY = SupportDraftVocab.SPACE_KEY_CASE_MINED;

    // ---- seams ----

    public interface Llm { String complete(String modelName, String prompt); }

    private class EinsteinLlm implements Llm {
        public String complete(String modelName, String prompt) {
            return EinsteinAiClient.chat(modelName, prompt);
        }
    }
    @TestVisible private static Llm llm = new EinsteinLlm();
    @TestVisible private static SupportRetrievalService.EmbeddingClient embedder =
        SupportRetrievalService.embeddingClient();

    // ---- inputs / state (serialized with the Queueable across re-enqueues) ----

    public class SeedTopic {
        public String slug;               // -> pageId 'case-mined:seed:<slug>'
        public String title;
        public List<String> searchTerms;  // verbatim error strings / distinctive phrases
        public String product;
        public SeedTopic() {}
        public SeedTopic(String slug, String title, List<String> searchTerms, String product) {
            this.slug = slug; this.title = title; this.searchTerms = searchTerms; this.product = product;
        }
    }

    public class HarvestRow {
        public String caseId;
        public String caseNumber;
        public String subject;
        public String product;
        public String question;         // <= QUESTION_MAX
        public String resolution;       // <= RESOLUTION_MAX, condensed from the agent's own words
        public List<String> errorStrings = new List<String>();
    }

    public class Cluster {
        public String seedSlug;          // null for organic clusters
        public String title;             // seed title, else filled at generation
        public String product;
        public List<Integer> members = new List<Integer>(); // indices into harvested
    }

    /** One line per cluster/doc decision — the run's audit trail. */
    public class Outcome {
        public String key;      // seed slug or 'cluster-<n>'
        public String action;   // ACCEPTED | SKIP_DUPLICATE | REJECT_UNSUPPORTED | REJECT_GATES |
                                // SKIP_MODEL | SEED_UNMATCHED | ERROR
        public String detail;
        public String pageId;
        public List<String> caseNumbers = new List<String>();
    }

    /**
     * Everything a chain link needs to resume, carried across re-enqueues as ONE named-field
     * object (the previous 12-positional-argument constructor was a transposition hazard).
     */
    public class State {
        public String runLabel;
        public String phase = 'HARVEST';     // HARVEST | CLUSTER | GENERATE
        public List<Id> cohort = new List<Id>();   // fixed at kickoff
        public Integer cursor = 0;           // case cursor (HARVEST) or cluster cursor (GENERATE)
        public Integer depth = 0;
        public List<SeedTopic> seeds = new List<SeedTopic>();
        public List<HarvestRow> harvested = new List<HarvestRow>();
        public List<Cluster> clusters = new List<Cluster>();
        public List<Outcome> outcomes = new List<Outcome>();
        public Integer skippedIntake = 0;    // junk/billing cases dropped pre-harvest
        public Integer skippedNoReply = 0;
        public Integer skippedNotSubstantive = 0;
    }

    private final State s;

    public CaseMiningJob(List<Id> cohort, List<SeedTopic> seeds, String runLabel) {
        State st = new State();
        st.runLabel = runLabel;
        if (cohort != null) { st.cohort = cohort; }
        if (seeds != null) { st.seeds = seeds; }
        this.s = normalize(st);
    }

    @TestVisible
    private CaseMiningJob(State st) {
        this.s = normalize(st);
    }

    private static State normalize(State st) {
        if (st == null) { st = new State(); }
        if (String.isBlank(st.runLabel)) { st.runLabel = 'mining'; }
        if (st.cohort == null) { st.cohort = new List<Id>(); }
        if (st.seeds == null) { st.seeds = new List<SeedTopic>(); }
        if (st.harvested == null) { st.harvested = new List<HarvestRow>(); }
        if (st.clusters == null) { st.clusters = new List<Cluster>(); }
        if (st.outcomes == null) { st.outcomes = new List<Outcome>(); }
        return st;
    }

    public void execute(QueueableContext ctx) {
        if (s.depth >= MAX_DEPTH) {
            saveReport('PARTIAL (MAX_DEPTH at phase ' + s.phase + ' cursor ' + s.cursor + ')');
            return;
        }
        if (s.phase == 'HARVEST') { runHarvest(); }
        else if (s.phase == 'CLUSTER') { runCluster(); }
        else { runGenerate(); }
    }

    private void chain(CaseMiningJob next) {
        if (!Test.isRunningTest()) { System.enqueueJob(next); }
    }

    /** Advance the shared state to the next link (enqueue serializes it with the job). */
    private State next(String phase, Integer cursor) {
        s.phase = phase;
        s.cursor = cursor;
        s.depth++;
        return s;
    }

    // ---- phase HARVEST ----

    private void runHarvest() {
        Integer endIdx = Math.min(s.cursor + HARVEST_CHUNK, s.cohort.size());
        List<Id> slice = new List<Id>();
        for (Integer i = s.cursor; i < endIdx; i++) { slice.add(s.cohort[i]); }

        Map<Id, Case> byId = new Map<Id, Case>([
            SELECT Id, CaseNumber, Subject, Description, Product_List__c, SuppliedEmail
            FROM Case WHERE Id IN :slice
        ]);
        Map<Id, String> replies = outboundReplyText(slice);

        for (Id cid : slice) {
            Case c = byId.get(cid);
            if (c == null) { continue; }
            CaseIntakeClassifier.Verdict v =
                CaseIntakeClassifier.classify(c.Subject, c.Description, c.SuppliedEmail);
            if (v.category != CaseIntakeClassifier.CATEGORY_LEGIT) { s.skippedIntake++; continue; }
            String reply = replies.get(cid);
            if (String.isBlank(reply) || reply.length() < MIN_REPLY_CHARS) { s.skippedNoReply++; continue; }

            HarvestRow row = extractOne(c, reply);
            if (row == null) { s.skippedNotSubstantive++; continue; }
            s.harvested.add(row);
        }

        if (endIdx < s.cohort.size()) {
            chain(new CaseMiningJob(next('HARVEST', endIdx)));
        } else {
            saveCheckpoint('harvest', new Map<String, Object>{
                'harvested' => s.harvested.size(), 'skippedIntake' => s.skippedIntake,
                'skippedNoReply' => s.skippedNoReply, 'skippedNotSubstantive' => s.skippedNotSubstantive });
            chain(new CaseMiningJob(next('CLUSTER', 0)));
        }
    }

    /** Concatenated outbound (agent) reply text per case, oldest first, capped per case.
     *  The cap keeps the thread OPENING plus the TAIL: the resolution normally lives in the LAST
     *  reply, and the old head-only cap silently cut it off — the 07-21b run killed 253/420 cases
     *  as "not substantive" largely because harvest never saw the fix. */
    private static Map<Id, String> outboundReplyText(List<Id> caseIds) {
        Map<Id, String> merged = new Map<Id, String>();
        for (EmailMessage em : [
            SELECT ParentId, TextBody, HtmlBody FROM EmailMessage
            WHERE ParentId IN :caseIds AND Incoming = false
            ORDER BY CreatedDate ASC
        ]) {
            String text = String.isNotBlank(em.TextBody)
                ? em.TextBody : SupportSolutionStore.stripHtml(em.HtmlBody);
            if (String.isBlank(text)) { continue; }
            text = stripQuotedHistory(text.trim());
            String existing = merged.get(em.ParentId);
            merged.put(em.ParentId, (existing == null) ? text : existing + '\n---\n' + text);
        }
        Map<Id, String> out = new Map<Id, String>();
        for (Id cid : merged.keySet()) {
            String full = merged.get(cid);
            out.put(cid, full.length() <= REPLY_CAP_PER_CASE
                ? full
                : full.substring(0, REPLY_HEAD_KEEP) + '\n…\n'
                    + full.substring(full.length() - (REPLY_CAP_PER_CASE - REPLY_HEAD_KEEP - 3)));
        }
        return out;
    }

    /** Cut the quoted thread below common reply markers so only the agent's words remain. */
    @TestVisible
    private static String stripQuotedHistory(String text) {
        for (String marker : new List<String>{ '\nFrom: ', '\n> ', '\nOn ', '\n-----Original Message-----' }) {
            Integer idx = text.indexOf(marker);
            // 'On ' only counts as a reply header when followed by 'wrote:' nearby (locale-tolerant).
            if (idx > 0 && (marker != '\nOn ' || text.indexOf('wrote:', idx) > idx)) {
                text = text.substring(0, idx);
            }
        }
        return text.trim();
    }

    private HarvestRow extractOne(Case c, String reply) {
        String prompt = 'You extract knowledge-base raw material from a resolved support case.\n'
            + 'CUSTOMER SUBJECT: ' + blank(c.Subject) + '\n'
            + 'CUSTOMER QUESTION:\n' + head(blank(c.Description), 2000) + '\n\n'
            + 'AGENT REPLIES (the authoritative content — separated by ---):\n' + reply + '\n\n'
            + 'Rules:\n'
            + '- resolution_summary MUST be a condensation of the agent\'s own words from the replies.'
            + ' Never add steps, settings, or facts the agent did not state.\n'
            + '- If the replies contain no actual resolution (e.g. "escalating", "can you send a'
            + ' screenshot", "let\'s schedule a call"), set substantive=false.\n'
            + '- error_strings: verbatim product error messages quoted in the case, if any.\n'
            + '- product: "S-Docs", "S-Sign", or "" if unclear.\n'
            + 'Output ONLY minified JSON: {"question_summary":"<=300 chars","resolution_summary":'
            + '"<=800 chars","substantive":true|false,"error_strings":["..."],"product":"..."}';
        try {
            String raw = llm.complete(modelName(), prompt);
            Map<String, Object> parsed = EinsteinAiClient.parseModelJson(raw);
            if (parsed == null || parsed.get('substantive') != true) { return null; }
            HarvestRow row = new HarvestRow();
            row.caseId = String.valueOf(c.Id);
            row.caseNumber = c.CaseNumber;
            row.subject = c.Subject;
            row.product = String.isBlank((String) parsed.get('product'))
                ? c.Product_List__c : (String) parsed.get('product');
            row.question = head((String) parsed.get('question_summary'), QUESTION_MAX);
            row.resolution = head((String) parsed.get('resolution_summary'), RESOLUTION_MAX);
            if (String.isBlank(row.question) || String.isBlank(row.resolution)) { return null; }
            if (parsed.get('error_strings') instanceof List<Object>) {
                for (Object o : (List<Object>) parsed.get('error_strings')) {
                    if (o instanceof String && String.isNotBlank((String) o)) {
                        row.errorStrings.add(head((String) o, 200));
                    }
                }
            }
            return row;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Harvest extraction failed for ' + c.CaseNumber + ': '
                + e.getMessage());
            return null; // extraction failure = this case contributes nothing; the run continues
        }
    }

    // ---- phase CLUSTER (single link: vectors never cross a serialization boundary) ----

    private void runCluster() {
        // 1. Seeds claim their cases first (verbatim term match on subject/question/error strings).
        Set<Integer> claimed = new Set<Integer>();
        for (SeedTopic seed : s.seeds) {
            Cluster cl = new Cluster();
            cl.seedSlug = seed.slug;
            cl.title = seed.title;
            cl.product = seed.product;
            for (Integer i = 0; i < s.harvested.size(); i++) {
                if (claimed.contains(i)) { continue; }
                if (rowMatchesSeed(s.harvested[i], seed)) {
                    cl.members.add(i);
                    claimed.add(i);
                }
            }
            if (cl.members.isEmpty()) {
                Outcome o = new Outcome();
                o.key = seed.slug;
                o.action = 'SEED_UNMATCHED';
                o.detail = 'No harvested case matched this seed topic — no grounding material; '
                    + 'flag for human authoring.';
                s.outcomes.add(o);
            } else {
                s.clusters.add(cl);
            }
        }

        // 2. Organic clustering of the unclaimed remainder on question-embedding cosine.
        List<Integer> free = new List<Integer>();
        List<String> texts = new List<String>();
        for (Integer i = 0; i < s.harvested.size(); i++) {
            if (!claimed.contains(i)) { free.add(i); texts.add(s.harvested[i].question); }
        }
        List<List<Double>> vecs = embedBatched(texts);

        List<Integer> leaders = new List<Integer>();      // index into `free`/`vecs`
        List<Cluster> organic = new List<Cluster>();
        for (Integer f = 0; f < free.size(); f++) {
            Boolean placed = false;
            if (vecs != null && f < vecs.size() && vecs[f] != null) {
                for (Integer l = 0; l < leaders.size(); l++) {
                    List<Double> lv = vecs[leaders[l]];
                    if (lv != null && cosine(vecs[f], lv) >= CLUSTER_JOIN_COSINE) {
                        organic[l].members.add(free[f]);
                        placed = true;
                        break;
                    }
                }
            }
            if (!placed) {
                leaders.add(f);
                Cluster cl = new Cluster();
                cl.product = s.harvested[free[f]].product;
                cl.members.add(free[f]);
                organic.add(cl);
            }
        }
        // Only recurring topics (>=2 members) become doc candidates; singletons are parked.
        Integer singletons = 0;
        for (Cluster cl : organic) {
            if (cl.members.size() >= 2) { s.clusters.add(cl); } else { singletons++; }
        }

        saveCheckpoint('cluster', new Map<String, Object>{
            'clusters' => s.clusters.size(), 'singletonsParked' => singletons,
            'seedClusters' => countSeeded(), 'harvested' => s.harvested.size() });
        chain(new CaseMiningJob(next('GENERATE', 0)));
    }

    @TestVisible
    private static Boolean rowMatchesSeed(HarvestRow row, SeedTopic seed) {
        if (seed.searchTerms == null) { return false; }
        String hay = ((row.subject == null ? '' : row.subject) + ' ' + row.question + ' '
            + String.join(row.errorStrings, ' ')).toLowerCase();
        for (String term : seed.searchTerms) {
            if (String.isNotBlank(term) && hay.contains(term.toLowerCase())) { return true; }
        }
        return false;
    }

    private List<List<Double>> embedBatched(List<String> texts) {
        List<List<Double>> out = new List<List<Double>>();
        for (Integer i = 0; i < texts.size(); i += EMBED_BATCH) {
            List<String> batch = new List<String>();
            for (Integer j = i; j < Math.min(i + EMBED_BATCH, texts.size()); j++) { batch.add(texts[j]); }
            try {
                List<List<Double>> vecs = embedder.embed(embeddingModelName(), batch);
                for (Integer j = 0; j < batch.size(); j++) {
                    out.add(vecs != null && j < vecs.size() ? vecs[j] : null);
                }
            } catch (Exception e) {
                // Un-embeddable batch -> those rows become singleton leaders (parked), run continues.
                for (Integer j = 0; j < batch.size(); j++) { out.add(null); }
            }
        }
        return out;
    }

    @TestVisible
    private static Double cosine(List<Double> a, List<Double> b) {
        if (a == null || b == null || a.size() != b.size()) { return -1; }
        Double dot = 0, na = 0, nb = 0;
        for (Integer i = 0; i < a.size(); i++) {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i];
        }
        if (na == 0 || nb == 0) { return -1; }
        return dot / (Math.sqrt(na) * Math.sqrt(nb));
    }

    // ---- phase GENERATE ----

    private void runGenerate() {
        Integer endIdx = Math.min(s.cursor + GENERATE_CHUNK, s.clusters.size());
        for (Integer i = s.cursor; i < endIdx; i++) {
            processCluster(i);
        }
        if (endIdx < s.clusters.size()) {
            chain(new CaseMiningJob(next('GENERATE', endIdx)));
        } else {
            saveReport(null);
            // Embedding backfill for everything just ingested (Embedding_Synced__c=false).
            if (!Test.isRunningTest()) { SupportSolutionStore.enqueue(); }
        }
    }

    private void processCluster(Integer idx) {
        Cluster cl = s.clusters[idx];
        Outcome o = new Outcome();
        o.key = (cl.seedSlug != null) ? cl.seedSlug : 'cluster-' + idx;
        for (Integer m : cl.members) { o.caseNumbers.add(s.harvested[m].caseNumber); }
        s.outcomes.add(o);
        try {
            // (a) grounding context: full agent replies of the strongest members
            List<Integer> grounding = new List<Integer>();
            for (Integer m : cl.members) {
                grounding.add(m);
                if (grounding.size() >= GROUNDING_CASES_MAX) { break; }
            }
            List<Id> gids = new List<Id>();
            for (Integer m : grounding) { gids.add(Id.valueOf(s.harvested[m].caseId)); }
            Map<Id, String> replies = outboundReplyText(gids);

            String sources = '';
            for (Integer m : grounding) {
                String r = replies.get(Id.valueOf(s.harvested[m].caseId));
                if (String.isBlank(r)) { continue; }
                sources += '=== CASE ' + s.harvested[m].caseNumber + ' ===\nCUSTOMER ASKED: '
                    + s.harvested[m].question + '\nAGENT REPLIED:\n' + r + '\n\n';
            }
            if (String.isBlank(sources)) {
                o.action = 'ERROR'; o.detail = 'No grounding replies could be re-read.'; return;
            }

            // (b) dedupe gate BEFORE spending generation: deterministic retrieve() against the
            // existing corpus; skip only when a non-mined doc STRONGLY answers already.
            HarvestRow rep = s.harvested[cl.members[0]];
            SupportRetrievalService.RetrievalInput rin = new SupportRetrievalService.RetrievalInput();
            rin.searchText = rep.question;
            rin.product = cl.product;
            SupportRetrievalService.RetrievalResult rr = SupportRetrievalService.retrieve(rin);
            if (rr.topScore >= DEDUPE_SKIP_SCORE && !topDocsAreMined(rr)) {
                o.action = 'SKIP_DUPLICATE';
                o.detail = 'Existing corpus already answers at ' + rr.topScore + ' (doc: '
                    + (rr.candidates.isEmpty() ? '?' : rr.candidates[0].name) + ').';
                return;
            }

            // (c) generation, grounded ONLY in the sources
            Map<String, Object> doc = generateDoc(cl, sources);
            if (doc == null) {
                o.action = 'SKIP_MODEL';
                o.detail = 'Model declined (incomplete/conflicting fix in sources) or unparseable output.';
                return;
            }

            // (d) adversarial verify: every claim must be supported by the sources
            String unsupported = verifyDoc(doc, sources);
            if (unsupported != null) {
                o.action = 'REJECT_UNSUPPORTED'; o.detail = unsupported; return;
            }

            // (e) mechanical gates + scrub
            String body = buildBody(doc);
            body = scrubPii(body);
            String gateFail = gateCheck(doc, body);
            if (gateFail != null) {
                o.action = 'REJECT_GATES'; o.detail = gateFail; return;
            }

            // (f) ingest
            SupportSolutionStore.PageInput p = new SupportSolutionStore.PageInput();
            p.pageId = pageIdFor(cl, o.caseNumbers);
            p.title = head((String) doc.get('title'), 80);
            p.htmlBody = body;
            p.sourceType = 'tribal';
            p.visibility = SupportDraftVocab.VIS_CUSTOMER_SAFE;
            p.solutionType = 'procedure';
            p.product = normalizeProduct(cl.product);
            p.keywords = head(keywordsFor(cl, doc), 255);
            p.sourceSpaceKey = SPACE_KEY;
            p.commonCase = cl.members.size() >= 4;
            p.isActive = true;
            SupportSolutionStore.IngestionResult ir =
                SupportSolutionStore.upsertPages(new List<SupportSolutionStore.PageInput>{ p });
            if (ir.processed != 1) {
                o.action = 'ERROR';
                o.detail = 'Upsert failed: ' + String.join(ir.errors, '; ');
                return;
            }
            stampProvenance(p.pageId, o.caseNumbers);
            o.action = 'ACCEPTED';
            o.pageId = p.pageId;
            o.detail = p.title;
        } catch (Exception e) {
            o.action = 'ERROR';
            o.detail = e.getTypeName() + ': ' + head(e.getMessage(), 300);
        }
    }

    private static Boolean topDocsAreMined(SupportRetrievalService.RetrievalResult rr) {
        if (rr.candidates.isEmpty() || rr.candidates[0].solutionId == null) { return false; }
        List<Support_Solution__c> docs = [
            SELECT Source_Space_Key__c FROM Support_Solution__c
            WHERE Id = :rr.candidates[0].solutionId LIMIT 1
        ];
        return !docs.isEmpty() && SPACE_KEY.equals(docs[0].Source_Space_Key__c);
    }

    private Map<String, Object> generateDoc(Cluster cl, String sources) {
        String topicHint = (cl.seedSlug != null)
            ? 'The doc must cover this specific topic: ' + cl.title + '.\n' : '';
        String prompt = 'You write a knowledge-base article for S-Docs/S-Sign customers, using ONLY '
            + 'facts stated in the agent replies below. These replies were written and sent by human '
            + 'support agents; they are the sole source of truth.\n' + topicHint
            + 'Rules:\n'
            + '- NEVER invent steps, settings, versions, or behavior not present in the replies.\n'
            + '- Anonymize completely: no customer names, no email addresses, no company names, no '
            + 'links to customer orgs.\n'
            + '- If the replies do not contain a complete, consistent fix, output exactly: SKIP\n'
            + '- Sections: problem (the symptom in customer terms, include verbatim error text if '
            + 'quoted), cause (only if the agent stated one), resolution (numbered steps in the '
            + 'agent\'s substance).\n'
            + 'Output ONLY minified JSON: {"title":"<=80 chars","problem":"...","cause":"..." (or '
            + 'empty),"resolution":"...","keywords":"space-separated search terms"}\n\n'
            + 'SOURCES:\n' + sources;
        String raw = llm.complete(modelName(), prompt);
        if (raw == null || raw.trim().equalsIgnoreCase('SKIP')) { return null; }
        Map<String, Object> doc = EinsteinAiClient.parseModelJson(raw);
        if (doc == null) { return null; }
        try {
            if (String.isBlank((String) doc.get('title'))
                    || String.isBlank((String) doc.get('resolution'))) { return null; }
            return doc;
        } catch (Exception e) {
            return null;
        }
    }

    /** Returns null when supported; else a short description of the unsupported claims. */
    private String verifyDoc(Map<String, Object> doc, String sources) {
        String prompt = 'You are a skeptical fact-checker. Below is a DRAFT knowledge-base article '
            + 'and the SOURCE agent replies it was derived from. List every claim in the draft '
            + '(step, setting, version, behavior) that is NOT supported by the sources. Be strict: '
            + 'paraphrase is fine, invention is not.\n'
            + 'Output ONLY minified JSON: {"verdict":"SUPPORTED"|"UNSUPPORTED","unsupported_claims":["..."]}\n\n'
            + 'DRAFT:\n' + JSON.serialize(doc) + '\n\nSOURCES:\n' + sources;
        try {
            String raw = llm.complete(modelName(), prompt);
            Map<String, Object> v = EinsteinAiClient.parseModelJson(raw);
            if (v == null) { return 'Verifier unavailable/unparseable: response was not valid JSON'; }
            if ('SUPPORTED'.equalsIgnoreCase((String) v.get('verdict'))) { return null; }
            List<Object> claims = (v.get('unsupported_claims') instanceof List<Object>)
                ? (List<Object>) v.get('unsupported_claims') : new List<Object>();
            return 'Verifier found unsupported claims: ' + head(JSON.serialize(claims), 400);
        } catch (Exception e) {
            // Parse/callout failure = cannot verify = do not ingest (fail closed on quality).
            return 'Verifier unavailable/unparseable: ' + head(e.getMessage(), 200);
        }
    }

    @TestVisible
    private static String buildBody(Map<String, Object> doc) {
        String cause = (String) doc.get('cause');
        return 'Problem\n' + blank((String) doc.get('problem')) + '\n\n'
            + (String.isBlank(cause) ? '' : 'Cause\n' + cause + '\n\n')
            + 'Resolution\n' + blank((String) doc.get('resolution'));
    }

    /** Redact emails/phones, strip non-allowlisted URLs. The generation prompt anonymizes; this is the backstop. */
    @TestVisible
    private static String scrubPii(String body) {
        String out = body.replaceAll('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}', '[email removed]');
        // Phone-ish: 10+ chars of digit punctuation with >=7 digits (version strings never qualify).
        Matcher m = Pattern.compile('\\+?[0-9][0-9 ().\\-]{8,}[0-9]').matcher(out);
        while (m.find()) {
            String hit = m.group();
            if (hit.replaceAll('[^0-9]', '').length() >= 7) {
                out = out.replace(hit, '[phone removed]');
            }
        }
        Matcher u = Pattern.compile('https?://[^\\s)>\\]]+').matcher(out);
        while (u.find()) {
            String url = u.group();
            if (!url.contains('sdocs.com') && !url.contains('salesforce.com')) {
                out = out.replace(url, '[link removed]');
            }
        }
        return out;
    }

    @TestVisible
    private static String gateCheck(Map<String, Object> doc, String body) {
        if (body.length() < BODY_MIN_CHARS) { return 'Body too short (' + body.length() + ' chars).'; }
        if (body.length() > BODY_MAX_CHARS) { return 'Body too long (' + body.length() + ' chars).'; }
        if (!body.contains('Resolution\n')) { return 'Missing Resolution section.'; }
        if (String.isBlank((String) doc.get('problem'))) { return 'Missing Problem section.'; }
        return null;
    }

    private static String pageIdFor(Cluster cl, List<String> caseNumbers) {
        if (cl.seedSlug != null) { return SPACE_KEY + ':seed:' + cl.seedSlug; }
        List<String> sorted = new List<String>(caseNumbers);
        sorted.sort();
        Blob digest = Crypto.generateDigest('SHA1', Blob.valueOf(String.join(sorted, ',')));
        return SPACE_KEY + ':' + EncodingUtil.convertToHex(digest).substring(0, 12);
    }

    private String keywordsFor(Cluster cl, Map<String, Object> doc) {
        Set<String> parts = new Set<String>();
        for (Integer m : cl.members) {
            for (String es : s.harvested[m].errorStrings) { parts.add(es); }
        }
        String kw = (String) doc.get('keywords');
        if (String.isNotBlank(kw)) { parts.add(kw); }
        return String.join(new List<String>(parts), ' ');
    }

    private static String normalizeProduct(String product) {
        if (String.isBlank(product)) { return null; }
        String p = product.trim();
        // A multi-product cluster stays untagged (blank = retrievable for every product filter).
        if (p.contains(';')) { return null; }
        return (p == 'S-Docs' || p == 'S-Sign') ? p : null;
    }

    private static void stampProvenance(String pageId, List<String> caseNumbers) {
        List<Support_Solution__c> recs = [
            SELECT Id FROM Support_Solution__c WHERE Confluence_Page_Id__c = :pageId LIMIT 1
        ];
        if (!recs.isEmpty()) {
            recs[0].Mined_From_Cases__c = head(String.join(caseNumbers, ', '), 4000);
            update recs[0];
        }
    }

    // ---- reporting ----

    private void saveCheckpoint(String phaseName, Map<String, Object> stats) {
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Case Mining ' + s.runLabel + ' ' + phaseName;
        cv.PathOnClient = 'case-mining-' + s.runLabel + '-' + phaseName + '.json';
        cv.VersionData = Blob.valueOf(JSON.serializePretty(stats));
        insert cv;
    }

    private void saveReport(String partialNote) {
        Map<String, Integer> byAction = new Map<String, Integer>();
        for (Outcome o : s.outcomes) {
            Integer n = byAction.get(o.action);
            byAction.put(o.action, (n == null ? 0 : n) + 1);
        }
        Map<String, Object> report = new Map<String, Object>{
            'runLabel' => s.runLabel,
            'partial' => partialNote,
            'cohortSize' => s.cohort.size(),
            'harvested' => s.harvested.size(),
            'skippedIntake' => s.skippedIntake,
            'skippedNoReply' => s.skippedNoReply,
            'skippedNotSubstantive' => s.skippedNotSubstantive,
            'clusters' => s.clusters.size(),
            'actions' => byAction,
            'outcomes' => s.outcomes
        };
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Case Mining ' + s.runLabel + (partialNote == null ? '' : ' PARTIAL');
        cv.PathOnClient = 'case-mining-' + s.runLabel + '.json';
        cv.VersionData = Blob.valueOf(JSON.serializePretty(report));
        insert cv;
        System.debug(LoggingLevel.ERROR, 'CaseMiningJob ' + s.runLabel + ' done: '
            + JSON.serialize(byAction));
    }

    private Integer countSeeded() {
        Integer n = 0;
        for (Cluster cl : s.clusters) { if (cl.seedSlug != null) { n++; } }
        return n;
    }

    // ---- small helpers ----

    private static String modelName() {
        Support_Draft_Setting__mdt setting = Support_Draft_Setting__mdt.getInstance('Default');
        return (setting != null && String.isNotBlank(setting.Drafting_Model_Name__c))
            ? setting.Drafting_Model_Name__c : SupportDraftVocab.MODEL_DRAFTING_DEFAULT;
    }

    private static String embeddingModelName() {
        Support_Draft_Setting__mdt setting = Support_Draft_Setting__mdt.getInstance('Default');
        return (setting != null && String.isNotBlank(setting.Retrieval_Embedding_Model__c))
            ? setting.Retrieval_Embedding_Model__c : SupportDraftVocab.MODEL_EMBEDDING_DEFAULT;
    }

    private static String blank(String value) { return value == null ? '' : value; }

    private static String head(String value, Integer max) {
        if (value == null) { return null; }
        return value.length() > max ? value.substring(0, max) : value;
    }
}
