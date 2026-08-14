/**
 * Retrieval: SOSL candidate search (Tier 1 AND / Tier 2 OR) re-ranked by BM25F-lite lexical scoring
 * blended with embedding cosine, fused via RRF with a gated common-case priority boost, plus an
 * LLM query-distillation recovery pass for weak results. Stateless; config from Support_Draft_Setting__mdt.
 */
public with sharing class SupportRetrievalService {

    // Words too generic to help lexical match; dropped from the query.
    private static final Set<String> STOPWORDS = new Set<String>{
        'the','and','for','with','this','that','was','are','not','you','your','our','have','has',
        'can','cannot','help','issue','problem','please','hi','hello','team','support','case','about',
        'when','where','why','how','from','they','them','will','would','could','should','any','all',
        'too','into','via'
    };

    // Query breadth cap. High-signal (error-code/quoted) tokens are prepended, then document-order
    // tokens fill the remainder — so a buried verbatim error string still reaches the SOSL pool + scorer.
    private static final Integer QUERY_TERM_CAP = 12;
    private static final Integer HIGH_SIGNAL_CAP = 5;

    // BM25F-lite scoring constants (field weights, length normalization, saturation, blend weights).
    private static final Double W_TITLE = 3.0;
    private static final Double W_KW    = 2.0;
    private static final Double W_BODY  = 1.0;
    private static final Double B_TITLE = 0.5;
    private static final Double B_KW    = 0.0;   // keywords are a tag list; don't length-normalize
    private static final Double B_BODY  = 0.75;
    private static final Double K1      = 1.2;
    private static final Double WC_COV   = 0.62; // blend weights renormalize when a signal is N/A
    private static final Double WC_PROX  = 0.20;
    private static final Double WC_EXACT = 0.18;
    // coverage = matchQuality(P) * idfRecall(R)^0.5 — recall dampened so diluted-but-correct matches lift.
    private static final Double RECALL_DAMP = 0.5;
    private static final Integer BODY_TOKEN_CAP = 4000; // bound CPU: tokenize only the first N body chars

    // Semantic blend: score = (1-w)*lexical + w*rescaledCosine; falls back to pure lexical when N/A.
    private static final Double EMBED_WEIGHT_DEFAULT = 0.55;
    private static final String EMBED_MODEL_DEFAULT = SupportDraftVocab.MODEL_EMBEDDING_DEFAULT;
    // ada-002 cosines compress into a high band; rescale [floor, ceil] -> [0,1] to stay discriminative.
    private static final Double EMBED_SIM_FLOOR_DEFAULT = 0.70;
    private static final Double EMBED_SIM_CEIL_DEFAULT  = 0.90;

    // RRF fusion + common-case priority, hardcoded to the tuned live values.
    private static final Double RRF_K = 60;
    private static final Double PRIORITY_WEIGHT = 2.0;
    // Gate taus: content is the PRIMARY gate (raw cosine sits at ada-002's noise floor and admits everything).
    private static final Double PRIORITY_TAU_SEM = 0.76;
    private static final Double PRIORITY_TAU_LEX = 0.45;
    private static final Integer PRIORITY_MAX_PROMO_DEFAULT = 2;
    private static final Double PRIORITY_TAU_CONTENT = 0.45;
    // No-leapfrog: priority may break a near-tie but never override a materially better answer.
    private static final Double PRIORITY_LEAPFROG_MARGIN = 0.05;

    // Query distillation: one LLM call to recover customer-phrasing recall misses on weak results.
    private static final String QUERY_DISTILL_MODEL_DEFAULT = SupportDraftVocab.MODEL_DRAFTING_DEFAULT;
    private static final Double DISTILL_TRIGGER_SCORE_DEFAULT =
        SupportDraftVocab.DRAFT_FLOOR.doubleValue(); // = draft floor
    // content = max(blend, frac*lexical): a weak embedding must not score worse than no embedding.
    private static final Double LEXICAL_FLOOR_FRAC_DEFAULT = 0.0;
    // The distiller is sampled (no temperature control), so acceptance is outcome-based: the distilled
    // pass must reach draftable strength AND beat the deterministic first pass by this margin.
    private static final Double DISTILL_ACCEPT_MARGIN_DEFAULT = 0.10;

    public interface EmbeddingClient {
        List<List<Double>> embed(String modelName, List<String> texts);
    }

    public class EinsteinEmbeddingClient implements EmbeddingClient {
        public List<List<Double>> embed(String modelName, List<String> texts) {
            return EinsteinAiClient.embed(modelName, texts);
        }
    }

    @TestVisible
    private static EmbeddingClient embedClient = new EinsteinEmbeddingClient();

    public interface QueryDistiller {
        String distill(String modelName, String caseText);
    }

    public class EinsteinQueryDistiller implements QueryDistiller {
        public String distill(String modelName, String caseText) {
            if (String.isBlank(caseText)) { return ''; }
            return EinsteinAiClient.chat(modelName, buildDistillPrompt(caseText));
        }
    }

    @TestVisible
    private static QueryDistiller distiller = new EinsteinQueryDistiller();

    // Test overrides for mdt-driven config (mdt is unwritable in tests); non-null only in test context.
    @TestVisible private static Boolean testForceQueryDistill;
    @TestVisible private static Double  testForceLexicalFloorFrac;
    @TestVisible private static Double  testForceDistillAcceptMargin;

    @TestVisible
    private static String buildDistillPrompt(String caseText) {
        return 'You convert a raw customer support email into a concise knowledge-base SEARCH QUERY.\n'
            + 'Keep ONLY the words that identify: the product feature involved, the symptom or error, and the '
            + 'action the customer is trying to perform. DROP greetings, sign-offs, names, company names, '
            + 'case/record/order/ticket numbers, dates, urgency, and pleasantries.\n'
            + 'Use ONLY words that appear in the email (plus the product name when it is obvious); do not '
            + 'paraphrase or introduce synonyms. Keep the words in the order they appear in the email. '
            + 'Given the same email, always output the same words.\n'
            + 'Output ONLY the search keywords as one lowercase space-separated phrase of 4 to 8 words '
            + '(no punctuation, no explanation, no quotes).\n\nEMAIL:\n' + caseText;
    }

    @TestVisible private static Boolean testForceEmbedding;
    @TestVisible private static Boolean testForcePriorityEnabled;
    @TestVisible private static Integer testForcePriorityMaxPromo;

    @TestVisible
    private static List<Double> embedOne(String modelName, String text) {
        if (String.isBlank(text)) { return null; }
        List<List<Double>> vecs = embedClient.embed(modelName, new List<String>{ text });
        return (vecs == null || vecs.isEmpty()) ? null : vecs[0];
    }

    public static EmbeddingClient embeddingClient() { return embedClient; }

    public class RetrievalInput {
        public String searchText;   // subject + description + keywords, free text
        public String product;      // S-Docs / S-Sign (triage topic) - pre-filter; blank = both
        public Integer maxCandidates;
    }

    /** The per-doc sub-signals RRF fusion and confidence read (the fused Candidate.score is rank-based). */
    public class ScoreBreakdown {
        public Double lexical;      // blended lexical content [0,1]
        public Double semantic;     // rescaled cosine actually blended [0,1], -1 = N/A
        public Double semanticRaw;  // raw cosine before rescale [-1,1], -1 = N/A
        public Double content;      // calibrated blended score [0,1] — feeds topScore/confidence
    }

    public class Candidate implements Comparable {
        public Id solutionId;
        public String name;
        public String product;
        public String sourceType;
        public String visibility;             // customer_safe / agent_only / escalate_only
        public String solutionType;           // template / procedure / reference / explainer
        public Boolean commonCase = false;    // curated common case (priority-eligible)
        public Boolean hasRequiredDisclaimer; // drafting fetches the text by Id when true
        public String url;
        public String confluencePageId;
        public String snippet;
        public Decimal score;
        public Integer tier;
        public ScoreBreakdown breakdown;

        public Integer compareTo(Object o) {
            Candidate other = (Candidate) o;
            if (this.score != other.score) {
                return (this.score < other.score) ? 1 : -1; // descending by relevance
            }
            // Trust breaks exact score ties only, so the feed order is deterministic.
            Decimal tw = trustWeight(this.sourceType);
            Decimal ow = trustWeight(other.sourceType);
            if (tw != ow) { return (tw < ow) ? 1 : -1; }
            return 0;
        }
    }

    public class RetrievalResult {
        public List<Candidate> candidates = new List<Candidate>();
        public String confidence = 'NONE';   // HIGH | MEDIUM | LOW | NONE
        public Decimal topScore = 0;
        public Boolean hasGoodMatch = false;
        public Integer tier = 0;             // which tier produced the results (0 = none)
        public List<String> queryTerms = new List<String>();
        public Boolean distilled = false;    // a distilled second pass won and was returned
        public String distilledQuery;        // what the distiller produced (recorded even if unused)
    }

    @TestVisible
    private class Config {
        Integer poolLimit = 40;
        Integer maxCandidates = 5;       // inclusion ceiling / context budget, not a fixed top-N
        Decimal goodScore = SupportDraftVocab.DRAFT_FLOOR; // HIGH bar (= the pipeline draft floor)
        Decimal mediumScore = 0.30;      // MEDIUM bar
        Double selectAbsFloor = 0.20;    // adaptive-selection guardrails
        Double selectRelFrac  = 0.60;
        Double clusterGap     = 0.30;
        Boolean embeddingEnabled = false;
        String  embeddingModel   = EMBED_MODEL_DEFAULT;
        Double  embeddingWeight  = EMBED_WEIGHT_DEFAULT;
        Double  embeddingSimFloor = EMBED_SIM_FLOOR_DEFAULT;
        Double  embeddingSimCeil  = EMBED_SIM_CEIL_DEFAULT;
        Boolean priorityEnabled   = true;
        Boolean queryDistillEnabled = false;
        String  queryDistillModel   = QUERY_DISTILL_MODEL_DEFAULT;
        Double  distillTriggerScore = DISTILL_TRIGGER_SCORE_DEFAULT;
        Double  distillAcceptMargin = DISTILL_ACCEPT_MARGIN_DEFAULT;
        Double  lexicalFloorFrac    = LEXICAL_FLOOR_FRAC_DEFAULT;
        Integer priorityMaxPromo  = PRIORITY_MAX_PROMO_DEFAULT;
    }

    public static RetrievalResult retrieve(RetrievalInput input) {
        RetrievalResult result = new RetrievalResult();
        if (input == null || String.isBlank(input.searchText)) {
            return result; // NONE -> fallback
        }

        Config cfg = loadConfig();
        // Strip email boilerplate (signatures, forwarded headers, legal disclaimers, URLs) BEFORE both
        // term extraction and query embedding. Buried-error cases were losing the 10-term budget - and
        // polluting the query embedding - to signature/disclaimer noise. Fall back to the raw text if the
        // strip left nothing searchable.
        String cleanText = stripBoilerplate(input.searchText);
        List<String> terms = buildQueryTerms(cleanText);
        if (terms.isEmpty()) {
            cleanText = input.searchText;
            terms = buildQueryTerms(cleanText);
        }
        result.queryTerms = terms;
        if (terms.isEmpty()) {
            return result; // nothing searchable -> NONE
        }

        // Multi-select values arrive verbatim from Case.Product_List__c (e.g. 'S-Docs;S-Sign');
        // each token filters independently so a multi-product case searches every listed product.
        List<String> products = splitProducts(input.product);

        // Tier 1: strict AND (precision). Tier 2: broadened OR (recall) only if Tier 1 misses.
        Integer tier = 1;
        List<Support_Solution__c> hits = soslSearch(terms, true, products, cfg.poolLimit);
        if (hits.isEmpty()) {
            tier = 2;
            hits = soslSearch(terms, false, products, cfg.poolLimit);
        }
        // Verbatim error-string channel: when retrieval is already weak (tier-2 OR, or both tiers
        // empty), prose-term matches can crowd the error-carrying doc out of the LIMITed pool. A
        // dedicated OR pass on ONLY the high-signal tokens (quoted error strings, identifiers)
        // guarantees those docs enter the pool; the union is scored with pool-relative stats as one
        // set. Costs one extra SOSL only on weak retrievals; tier-1 AND pools already contain the
        // high-signal terms because buildQueryTerms prepends them. The budget guard degrades
        // gracefully in multi-case transactions (the eval/mining chains): skipping the channel is
        // the pre-channel behavior, never a governor exception.
        List<String> hsTerms = extractHighSignalTerms(cleanText);
        if (!hsTerms.isEmpty() && (tier == 2 || hits.isEmpty())
                && Limits.getSoslQueries() < Limits.getLimitSoslQueries()) {
            hits = unionById(hits, soslSearch(hsTerms, false, products, cfg.poolLimit));
        }
        if (hits.isEmpty()) {
            return result; // NONE -> fallback (SOSL recall ceiling reached)
        }
        result.tier = tier;

        // Embed the query once; any failure falls back to pure lexical (retrieval never hard-fails).
        List<Double> queryVec = null;
        if (cfg.embeddingEnabled) {
            try {
                queryVec = embedOne(cfg.embeddingModel, cleanText);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Query embedding failed, using lexical only: ' + e.getMessage());
            }
        }

        // Score against pool-relative stats (IDF + avg field lengths come from the hit pool).
        Scorer scorer = buildScorer(hits, terms, queryVec, cfg);
        List<Candidate> scored = new List<Candidate>();
        for (Integer i = 0; i < hits.size(); i++) {
            Candidate c = toCandidate(hits[i], tier);
            ScoredDoc sd = scorer.score(i);
            c.score = sd.score;        // blended content; overwritten by the RRF fusion below
            c.breakdown = sd.breakdown;
            scored.add(c);
        }

        applyRrfFusion(scored, cfg);
        scored.sort();

        Integer ceiling = (input.maxCandidates != null && input.maxCandidates > 0)
            ? input.maxCandidates : cfg.maxCandidates;
        result.candidates = selectAdaptive(scored, cfg, ceiling);

        // Confidence/topScore read the CALIBRATED content signal, not the rank-based fusion score, so the
        // HIGH/MEDIUM bars and the downstream drafting floor keep their meaning. RRF ranks on
        // lexical+semantic reciprocal rank, so the strongest content evidence may sit below rank 1 —
        // take the max across the fed set rather than trusting rank 1 alone.
        Double topContent = contentMax(result.candidates);
        if (topContent == null) {
            return result; // NONE -> fallback (selection produced no candidates)
        }
        result.topScore = Decimal.valueOf(topContent).setScale(4, System.RoundingMode.HALF_UP);
        result.hasGoodMatch = result.topScore >= cfg.goodScore;
        result.confidence = classifyConfidence(result.topScore, cfg);
        return result;
    }

    /**
     * retrieve(), plus a one-call LLM query-distillation retry when the first pass comes back below the
     * draft floor. Distillation can only help: a weaker/marginal/failed second pass is discarded.
     */
    public static RetrievalResult retrieveResilient(RetrievalInput input) {
        RetrievalResult r1 = retrieve(input);

        Config cfg = loadConfig();
        if (!cfg.queryDistillEnabled || input == null || String.isBlank(input.searchText)) { return r1; }

        Double top1 = (r1.topScore == null) ? 0 : r1.topScore.doubleValue();
        if (top1 >= cfg.distillTriggerScore) { return r1; }

        String distilledQuery = null;
        try {
            distilledQuery = distiller.distill(cfg.queryDistillModel, input.searchText);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Query distillation failed, keeping lexical pass: ' + e.getMessage());
        }
        if (String.isBlank(distilledQuery)) { return r1; }
        distilledQuery = distilledQuery.trim();

        // A distilled query that adds nothing new over the original is not worth a second retrieval.
        if (distilledQuery.equalsIgnoreCase(input.searchText.trim())) {
            r1.distilledQuery = distilledQuery;
            return r1;
        }

        RetrievalInput input2 = new RetrievalInput();
        input2.searchText = distilledQuery;
        input2.product = input.product;
        input2.maxCandidates = input.maxCandidates;
        RetrievalResult r2 = retrieve(input2);
        r2.distilledQuery = distilledQuery;

        Double top2 = (r2.topScore == null) ? 0 : r2.topScore.doubleValue();
        // Outcome-based acceptance: the distilled query is sampled (no temperature control), so it must
        // reach draftable strength AND decisively beat the deterministic first pass to replace it.
        if (top2 >= cfg.distillTriggerScore && top2 > top1 + cfg.distillAcceptMargin) {
            r2.distilled = true;
            return r2;
        }
        r1.distilledQuery = distilledQuery;
        return r1;
    }

    // ---- internals ----

    private static List<Support_Solution__c> soslSearch(
            List<String> terms, Boolean andMode, List<String> products, Integer poolLimit) {
        List<String> wild = new List<String>();
        for (String t : terms) { wild.add(t + '*'); } // prefix wildcard for light stemming
        // terms are cleaned to [a-z0-9] in extractTerms, so the expression is injection-safe.
        String expr = String.join(wild, andMode ? ' AND ' : ' OR ');

        // Exclude internal/unreviewed source types from the pool entirely (defense in depth with
        // draft()'s trust gate). '!=' also matches null, so unclassified rows are still retrieved.
        String whereClause = 'Active__c = true AND Source_Type__c != \'query\' '
            + 'AND Source_Type__c != \'draft\' AND Source_Type__c != \'internal_ops\'';
        if (products != null) { whereClause += ' AND Product__c IN :products'; }

        // Note: Required_Disclaimer_Text__c (Long Text) is intentionally NOT in the SOSL field list;
        // drafting fetches it by Id only when Has_Required_Disclaimer__c is true.
        String q = 'FIND \'' + expr + '\' IN ALL FIELDS RETURNING Support_Solution__c '
            + '(Id, Name, Body__c, Keywords__c, Source_Type__c, Product__c, Confluence_URL__c, '
            + 'Confluence_Page_Id__c, Visibility__c, Solution_Type__c, Has_Required_Disclaimer__c, '
            + 'Common_Case__c, Embedding__c '
            + 'WHERE ' + whereClause + ' LIMIT ' + poolLimit + ')';

        List<List<SObject>> res = Search.query(q);
        return (List<Support_Solution__c>) res[0];
    }

    /** Primary pool first, then channel additions it lacks; order-preserving Id-dedupe. Inputs are
     *  each capped at poolLimit, so the union never exceeds 2x poolLimit. */
    @TestVisible
    private static List<Support_Solution__c> unionById(
            List<Support_Solution__c> a, List<Support_Solution__c> b) {
        List<Support_Solution__c> out = new List<Support_Solution__c>();
        Set<Id> seen = new Set<Id>();
        for (Support_Solution__c s : a) { if (seen.add(s.Id)) { out.add(s); } }
        for (Support_Solution__c s : b) { if (seen.add(s.Id)) { out.add(s); } }
        return out;
    }

    /** Strongest calibrated content signal across the fed set; null when the set is empty. */
    @TestVisible
    private static Double contentMax(List<Candidate> candidates) {
        Double best = null;
        for (Candidate cand : candidates) {
            Double c = (cand.breakdown != null && cand.breakdown.content != null)
                ? cand.breakdown.content : cand.score.doubleValue();
            if (best == null || c > best) { best = c; }
        }
        return best;
    }

    /** Splits a (possibly multi-select) product value into filter tokens; null = no product filter. */
    @TestVisible
    private static List<String> splitProducts(String product) {
        if (String.isBlank(product)) { return null; }
        List<String> out = new List<String>();
        for (String p : product.split(';')) {
            if (!String.isBlank(p)) { out.add(p.trim()); }
        }
        return out.isEmpty() ? null : out;
    }

    /**
     * Remove email boilerplate that steals the query-term budget and pollutes the query embedding:
     * URLs, cid:/mailto: refs, email addresses, forwarded/quoted headers (From:/Sent:/To:/... and
     * "On <date> ... wrote:"), and confidentiality/legal disclaimer sentences. Conservative by design -
     * it strips only clearly non-content noise and never reorders the remaining text, so the case
     * subject (prepended first) and the actual issue keep their natural position.
     */
    @TestVisible
    private static String stripBoilerplate(String text) {
        if (String.isBlank(text)) { return text; }
        String t = text;
        t = t.replaceAll('(?i)https?://\\S+', ' ');
        t = t.replaceAll('(?i)www\\.\\S+', ' ');
        t = t.replaceAll('(?i)\\bcid:\\S+', ' ');
        t = t.replaceAll('(?i)\\bmailto:\\S+', ' ');
        t = t.replaceAll('(?i)[a-z0-9._%+\\-]+@[a-z0-9.\\-]+\\.[a-z]{2,}', ' ');
        // Forwarded / quoted email headers and attribution lines.
        t = t.replaceAll('(?im)^\\s*(from|sent|to|cc|bcc|subject|date|reply-to)\\s*:.*$', ' ');
        t = t.replaceAll('(?im)^\\s*on .{0,80}?\\bwrote:\\s*$', ' ');
        // Signature block: the closing-salutation line plus up to three short trailing lines
        // (name / title / company / phone). Bounded and shape-checked so it can never swallow a
        // quoted earlier email further down the thread — only line-length-limited non-content lines
        // directly under the salutation are dropped.
        t = t.replaceAll('(?im)^\\s*(thanks|thank you|many thanks|best|best regards|kind regards|'
            + 'regards|warm regards|cheers|sincerely)\\s*[,!.]?\\s*$'
            + '(\\r?\\n[^\\r\\n]{0,60}$){0,3}', ' ');
        // Confidentiality / legal disclaimer sentences (bounded so backtracking stays cheap).
        t = t.replaceAll(
            '(?is)\\b(this (e-?mail|message|transmittal|communication)|the information contained in this|'
            + 'confidentiality notice|important notice:|privacy notice:|as a healthcare entity)\\b'
            + '.{0,600}?(confidential|privileged|intended recipient|prohibited|unauthorized|dissemination|hipaa)\\b'
            + '.{0,160}?\\.', ' ');
        return t;
    }

    /**
     * The query term list: high-signal error tokens first (so a buried verbatim error string reaches
     * the SOSL pool AND scores via its high pool-IDF), then document-order tokens fill the remainder.
     * Falls back to pure document order when the case carries no error/identifier signal.
     */
    @TestVisible
    private static List<String> buildQueryTerms(String text) {
        List<String> out = new List<String>();
        Set<String> seen = new Set<String>();
        for (String h : extractHighSignalTerms(text)) {
            if (out.size() >= QUERY_TERM_CAP) { break; }
            if (seen.add(h)) { out.add(h); }
        }
        for (String t : extractTerms(text)) {
            if (out.size() >= QUERY_TERM_CAP) { break; }
            if (seen.add(t)) { out.add(t); }
        }
        return out;
    }

    /**
     * Distinctive, high-precision tokens that identify the actual problem: words inside quotes (error
     * messages like "Regex too complicated") and code-shaped identifiers (camelCase SDTemplateController /
     * SendEmail, ALL-CAPS stack frames, alnum error codes like SDCreate3). These are the verbatim signal
     * that a 10-term document-order query buries under email preamble. Case-sensitive input required.
     */
    @TestVisible
    private static List<String> extractHighSignalTerms(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) { return out; }
        Set<String> seen = new Set<String>();
        // 1. Quoted phrases (straight and smart quotes) — usually the verbatim error message.
        Matcher mq = Pattern.compile('["“‘’”\']([^"“”‘’\'\\n]{3,80})["“‘’”\']').matcher(text);
        while (mq.find()) {
            for (String w : mq.group(1).toLowerCase().split('[^a-z0-9]+')) { addHighSignal(out, seen, w); }
        }
        // 2. Code-shaped identifiers: camelCase, ALL-CAPS (>=8), or alnum-with-digit.
        Matcher mi = Pattern.compile('[A-Za-z]*[a-z][A-Z][A-Za-z]{2,}|[A-Z]{8,}|[A-Za-z]{2,}[0-9]+[A-Za-z0-9]*').matcher(text);
        while (mi.find()) { addHighSignal(out, seen, mi.group().toLowerCase()); }
        return out;
    }

    private static void addHighSignal(List<String> out, Set<String> seen, String raw) {
        if (out.size() >= HIGH_SIGNAL_CAP) { return; }
        String t = (raw == null) ? '' : raw.trim();
        if (t.length() < 3) { return; }
        if (STOPWORDS.contains(t)) { return; }
        if (seen.contains(t)) { return; }
        seen.add(t);
        out.add(t);
    }

    @TestVisible
    private static List<String> extractTerms(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) { return out; }
        Set<String> seen = new Set<String>();
        for (String raw : text.toLowerCase().split('[^a-z0-9]+')) {
            String t = raw.trim();
            if (t.length() < 3) { continue; }
            if (STOPWORDS.contains(t)) { continue; }
            if (seen.contains(t)) { continue; }
            seen.add(t);
            out.add(t);
            if (out.size() >= QUERY_TERM_CAP) { break; } // cap query breadth
        }
        return out;
    }

    private class DocTokens {
        List<String> title;
        List<String> kw;
        List<String> body;
        Set<String> allTokens;   // union (exact-equality lookups for high-signal terms)
        Integer lenTitle;
        Integer lenKw;
        Integer lenBody;
    }

    private class ScoredDoc {
        Decimal score;
        ScoreBreakdown breakdown;
    }

    private class Scorer {
        List<String> terms;
        List<Boolean> highSignal;        // parallel to terms: error-code / API-name shaped
        Boolean anyHighSignal;
        Map<String, Double> idf;         // per term, computed over the pool
        Double avgTitle;
        Double avgKw;
        Double avgBody;
        List<DocTokens> docs;
        List<EmbeddedVec> docVecs;       // parallel to docs: parsed Embedding__c (+ cached norm), or null
        List<Double> queryVec;           // the query embedding, or null (off / callout failed)
        Double queryVecSqNorm;           // |queryVec|^2, computed ONCE per case (not per doc)
        Double embeddingWeight;
        Double simFloor;                 // raw-cosine -> [0,1] rescale band (ada-002 compression fix)
        Double simCeil;
        Double lexicalFloorFrac;         // content >= lexicalFloorFrac * lexical (semantic can't subtract)

        ScoredDoc score(Integer i) {
            DocTokens d = docs[i];
            ScoreBreakdown b = new ScoreBreakdown();

            Double relevance = 0;       // Sigma over MATCHED terms of idf*saturation
            Double matchedIdf = 0;      // Sigma over MATCHED terms of idf (P's denominator)
            Double idealRelevance = 0;  // Sigma over ALL query terms of idf (R's denominator)
            for (Integer ti = 0; ti < terms.size(); ti++) {
                String t = terms[ti];
                Double tfTitle = prefixTf(d.title, t);
                Double tfKw    = prefixTf(d.kw, t);
                Double tfBody  = prefixTf(d.body, t);

                Double wtf =
                      W_TITLE * normTf(tfTitle, d.lenTitle, avgTitle, B_TITLE)
                    + W_KW    * normTf(tfKw,    d.lenKw,    avgKw,    B_KW)
                    + W_BODY  * normTf(tfBody,  d.lenBody,  avgBody,  B_BODY);

                Double idfT = idf.get(t);
                idealRelevance += idfT;
                if (wtf > 0) {
                    matchedIdf += idfT;
                    Double sat = wtf / (K1 + wtf);
                    relevance += idfT * sat;
                }
            }
            // P = match quality over what matched; R = how much query IDF mass matched (dampened).
            Double p = (matchedIdf > 0) ? (relevance / matchedIdf) : 0;
            Double r = (idealRelevance > 0) ? (matchedIdf / idealRelevance) : 0;
            Double coverageQuality = p * Math.pow(r, RECALL_DAMP);

            // Blend the content signals; renormalize when a signal does not apply.
            Double acc = WC_COV * coverageQuality;
            Double wsum = WC_COV;

            if (terms.size() >= 2) {
                acc += WC_PROX * proximityScore(d);
                wsum += WC_PROX;
            }

            if (anyHighSignal) {
                acc += WC_EXACT * exactHighSignalScore(d);
                wsum += WC_EXACT;
            }

            Double lexical = (wsum > 0) ? (acc / wsum) : 0;
            b.lexical = round4(lexical);

            // Semantic blend when both vectors are present; N/A falls straight back to pure lexical.
            Double sem = -1;
            Double semRaw = -1;
            Double finalScore = lexical;
            EmbeddedVec docVec = (docVecs == null) ? null : docVecs[i];
            if (queryVec != null && docVec != null) {
                Double cos = cosinePrecomputed(queryVec, queryVecSqNorm, docVec); // -2 sentinel on mismatch
                if (cos > -2) {
                    semRaw = cos;
                    sem = rescaleCosine(cos, simFloor, simCeil); // ada-002 band -> [0,1]
                    Double w = embeddingWeight;
                    finalScore = (1 - w) * lexical + w * sem;
                }
            }
            b.semantic = round4(sem);
            b.semanticRaw = round4(semRaw);

            // Lexical floor: a weak embedding must never score a doc below frac*its lexical evidence.
            if (lexicalFloorFrac > 0 && lexical > 0) {
                Double lexFloor = lexicalFloorFrac * lexical;
                if (finalScore < lexFloor) { finalScore = lexFloor; }
            }

            if (finalScore < 0) { finalScore = 0; }
            if (finalScore > 1) { finalScore = 1; }
            b.content = round4(finalScore);

            ScoredDoc sd = new ScoredDoc();
            sd.score = Decimal.valueOf(finalScore).setScale(4, System.RoundingMode.HALF_UP);
            sd.breakdown = b;
            return sd;
        }

        Double proximityScore(DocTokens d) {
            Integer possible = 0;
            Integer found = 0;
            Boolean titlePhrase = false;
            for (Integer i = 0; i < terms.size() - 1; i++) {
                String a = terms[i];
                String bb = terms[i + 1];
                Boolean aIn = containsPrefix(d.allTokens, a);
                Boolean bIn = containsPrefix(d.allTokens, bb);
                if (!aIn || !bIn) { continue; } // only pairs where both terms are present in the doc
                possible++;
                Boolean adjTitle = adjacent(d.title, a, bb);
                if (adjTitle) { titlePhrase = true; }
                if (adjTitle || adjacent(d.body, a, bb) || adjacent(d.kw, a, bb)) { found++; }
            }
            if (possible == 0) { return 0; }
            Double adjRatio = ((Double) found) / possible;
            return 0.7 * adjRatio + 0.3 * (titlePhrase ? 1 : 0);
        }

        Double exactHighSignalScore(DocTokens d) {
            Integer total = 0;
            Integer hit = 0;
            for (Integer i = 0; i < terms.size(); i++) {
                if (highSignal[i] != true) { continue; }
                total++;
                if (d.allTokens.contains(terms[i])) { hit++; } // exact equality, not prefix
            }
            return (total == 0) ? 0 : (((Double) hit) / total);
        }
    }

    /** Build the pool-aware scorer: tokenize each doc, compute avg field lengths and per-term IDF, and
     *  parse each doc's stored embedding for the optional semantic blend. */
    private static Scorer buildScorer(List<Support_Solution__c> pool, List<String> terms,
            List<Double> queryVec, Config cfg) {
        Scorer sc = new Scorer();
        sc.terms = terms;
        sc.docs = new List<DocTokens>();
        sc.docVecs = new List<EmbeddedVec>();
        sc.queryVec = queryVec;
        sc.queryVecSqNorm = sqNorm(queryVec); // once per case; identical for every doc
        sc.embeddingWeight = cfg.embeddingWeight;
        sc.simFloor = cfg.embeddingSimFloor;
        sc.simCeil = cfg.embeddingSimCeil;
        sc.lexicalFloorFrac = cfg.lexicalFloorFrac;
        sc.highSignal = new List<Boolean>();
        sc.anyHighSignal = false;
        for (String t : terms) {
            Boolean hs = isHighSignal(t);
            sc.highSignal.add(hs);
            if (hs) { sc.anyHighSignal = true; }
        }

        Double sumTitle = 0, sumKw = 0, sumBody = 0;
        for (Support_Solution__c s : pool) {
            DocTokens d = new DocTokens();
            d.title = tokenize(s.Name, 0);
            d.kw    = tokenize(s.Keywords__c, 0);
            d.body  = tokenize(s.Body__c, BODY_TOKEN_CAP);
            d.lenTitle = d.title.size();
            d.lenKw = d.kw.size();
            d.lenBody = d.body.size();
            d.allTokens = new Set<String>();
            d.allTokens.addAll(d.title);
            d.allTokens.addAll(d.kw);
            d.allTokens.addAll(d.body);
            sc.docs.add(d);
            sc.docVecs.add(queryVec == null ? null : cachedVector(s));
            sumTitle += d.lenTitle;
            sumKw += d.lenKw;
            sumBody += d.lenBody;
        }
        Integer n = pool.size();
        sc.avgTitle = (n > 0 && sumTitle > 0) ? (sumTitle / n) : 1;
        sc.avgKw    = (n > 0 && sumKw > 0)    ? (sumKw / n)    : 1;
        sc.avgBody  = (n > 0 && sumBody > 0)  ? (sumBody / n)  : 1;

        // IDF is POOL-relative (the SOSL hits for THIS query), not corpus-global — so the lexical
        // sub-score is not strictly comparable across queries; the pool-independent cosine carries that.
        sc.idf = new Map<String, Double>();
        for (String t : terms) {
            Integer df = 0;
            for (DocTokens d : sc.docs) {
                if (containsPrefix(d.allTokens, t)) { df++; }
            }
            // Robertson/Sparck-Jones style, always positive: ln(1 + (N - df + 0.5)/(df + 0.5)).
            Double v = Math.log(1 + (((Double) (n - df)) + 0.5) / (df + 0.5));
            sc.idf.put(t, v);
        }
        return sc;
    }

    /** BM25 length normalization for one field's term frequency. */
    private static Double normTf(Double tf, Integer len, Double avg, Double b) {
        if (tf <= 0) { return 0; }
        Double denom = (1 - b) + b * (((Double) len) / (avg <= 0 ? 1 : avg));
        return tf / (denom <= 0 ? 1 : denom);
    }

    private static Double prefixTf(List<String> toks, String term) {
        Double c = 0;
        for (String tk : toks) {
            if (tk.startsWith(term)) { c++; }
        }
        return c;
    }

    private static Boolean containsPrefix(Set<String> toks, String term) {
        // exact membership first (cheap), else any token starting with term.
        if (toks.contains(term)) { return true; }
        for (String tk : toks) {
            if (tk.startsWith(term)) { return true; }
        }
        return false;
    }

    private static Boolean adjacent(List<String> toks, String a, String b) {
        for (Integer k = 0; k < toks.size() - 1; k++) {
            String x = toks[k];
            String y = toks[k + 1];
            if ((x.startsWith(a) && y.startsWith(b)) || (x.startsWith(b) && y.startsWith(a))) {
                return true;
            }
        }
        return false;
    }

    // High-signal = identifier-shaped (error code / org id / API name): a digit or a long token.
    private static Boolean isHighSignal(String t) {
        if (t == null) { return false; }
        if (t.length() >= 10) { return true; }
        for (Integer i = 0; i < t.length(); i++) {
            if (t.substring(i, i + 1).isNumeric()) { return true; }
        }
        return false;
    }

    private static List<String> tokenize(String text, Integer cap) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) { return out; }
        String src = text.toLowerCase();
        if (cap > 0 && src.length() > cap) { src = src.substring(0, cap); }
        for (String raw : src.split('[^a-z0-9]+')) {
            if (raw.length() >= 2) { out.add(raw); }
        }
        return out;
    }

    private static Double round4(Double d) {
        if (d == null) { return null; }
        return Decimal.valueOf(d).setScale(4, System.RoundingMode.HALF_UP).doubleValue();
    }

    /** Cosine with precomputed norms (only the dot product runs per doc); -2 sentinel on mismatch. */
    private static Double cosinePrecomputed(List<Double> q, Double qSqNorm, EmbeddedVec doc) {
        if (q == null || doc == null || doc.values == null) { return -2; }
        List<Double> d = doc.values;
        if (q.isEmpty() || q.size() != d.size()) { return -2; }
        if (qSqNorm == null || qSqNorm <= 0 || doc.sqNorm <= 0) { return -2; }
        Double dot = 0;
        for (Integer i = 0; i < q.size(); i++) {
            dot += q[i] * d[i];
        }
        return dot / (Math.sqrt(qSqNorm) * Math.sqrt(doc.sqNorm));
    }

    private static Double sqNorm(List<Double> v) {
        if (v == null) { return 0; }
        Double s = 0;
        for (Integer i = 0; i < v.size(); i++) { Double x = v[i]; s += x * x; }
        return s;
    }

    /** Affinely map a raw cosine from [floor, ceil] onto [0,1] (ada-002's compressed band -> usable range). */
    @TestVisible
    private static Double rescaleCosine(Double cos, Double floorV, Double ceilV) {
        if (cos == null) { return 0; }
        Double lo = (floorV == null) ? EMBED_SIM_FLOOR_DEFAULT : floorV;
        Double hi = (ceilV == null) ? EMBED_SIM_CEIL_DEFAULT : ceilV;
        if (hi <= lo) { return cos < lo ? 0 : 1; }
        Double v = (cos - lo) / (hi - lo);
        if (v < 0) { return 0; }
        if (v > 1) { return 1; }
        return v;
    }

    /** A parsed embedding plus its precomputed squared norm, so the hot-path cosine skips the |doc| sum. */
    private class EmbeddedVec {
        List<Double> values;
        Double sqNorm;   // |values|^2, computed once at parse/cache time
    }

    // Transaction-scoped memo of parsed vectors; a null entry memoizes "no usable vector".
    private static Map<Id, EmbeddedVec> VECTOR_CACHE = new Map<Id, EmbeddedVec>();

    private static EmbeddedVec cachedVector(Support_Solution__c s) {
        if (s.Id != null && VECTOR_CACHE.containsKey(s.Id)) { return VECTOR_CACHE.get(s.Id); }
        List<Double> v = parseVector(s.Embedding__c);
        EmbeddedVec ev = null;
        if (v != null) {
            ev = new EmbeddedVec();
            ev.values = v;
            ev.sqNorm = sqNorm(v);
        }
        if (s.Id != null) { VECTOR_CACHE.put(s.Id, ev); }
        return ev;
    }

    @TestVisible
    private static List<Double> parseVector(String vectorJson) {
        if (String.isBlank(vectorJson)) { return null; }
        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(vectorJson);
            if (raw == null || raw.isEmpty()) { return null; }
            List<Double> out = new List<Double>();
            for (Object o : raw) {
                if (o == null) { return null; }
                out.add(Double.valueOf(o));
            }
            return out;
        } catch (Exception e) {
            return null; // a malformed vector simply contributes no semantic signal
        }
    }

    /**
     * Adaptive inclusion instead of a fixed top-N: keep docs above max(absFloor, relFrac*top), stop at the
     * first clusterGap relative drop, cap at `ceiling`. The top doc is always kept.
     */
    @TestVisible
    private static List<Candidate> selectAdaptive(List<Candidate> sorted, Config cfg, Integer ceiling) {
        List<Candidate> out = new List<Candidate>();
        if (sorted == null || sorted.isEmpty()) { return out; }

        Double top = sorted[0].score.doubleValue();
        Double floor = Math.max(cfg.selectAbsFloor, cfg.selectRelFrac * top);

        out.add(sorted[0]); // transparency: always surface the best match
        Double prevKept = top;
        for (Integer i = 1; i < sorted.size(); i++) {
            if (out.size() >= ceiling) { break; }              // context budget
            Double s = sorted[i].score.doubleValue();
            if (s < floor) { break; }                          // below the adaptive bar (list is sorted)
            if (prevKept > 0 && (prevKept - s) / prevKept >= cfg.clusterGap) {
                break;                                         // natural gap -> the strong cluster ended
            }
            out.add(sorted[i]);
            prevKept = s;
        }
        return out;
    }

    /**
     * Re-score the pool by reciprocal-rank fusion of the lexical + dense rank channels, boost gated
     * common cases (capped, no-leapfrog guarded), and normalize so the top doc is 1.0. Confidence and
     * topScore never read this score — they read the calibrated breakdown.content.
     */
    @TestVisible
    private static void applyRrfFusion(List<Candidate> docs, Config cfg) {
        Integer n = docs.size();
        if (n == 0) { return; }

        List<Double> lex = new List<Double>();
        List<Double> sem = new List<Double>();     // raw cosine, or -1 when N/A
        List<Double> content = new List<Double>(); // calibrated blended match [0,1]
        for (Candidate c : docs) {
            lex.add((c.breakdown != null && c.breakdown.lexical != null) ? c.breakdown.lexical : 0);
            sem.add((c.breakdown != null && c.breakdown.semanticRaw != null) ? c.breakdown.semanticRaw : -1);
            content.add((c.breakdown != null && c.breakdown.content != null) ? c.breakdown.content : 0);
        }

        // 1-based ranks; docs without a real cosine miss the dense channel and contribute 0 from it.
        Double semSkip = -1;
        List<Integer> lexRank = rankDesc(lex, null);
        List<Integer> semRank = rankDesc(sem, semSkip);

        List<Double> base = new List<Double>();
        for (Integer i = 0; i < n; i++) {
            Double v = recip(lexRank[i], RRF_K);
            if (sem[i] > -1) { v += recip(semRank[i], RRF_K); }
            base.add(v);
        }

        // Priority gate: content is the PRIMARY bar (raw cosine alone admits everything at ada-002's
        // noise floor); the sem/lex gate is an additional constraint.
        List<Integer> admitted = new List<Integer>();
        if (cfg.priorityEnabled) {
            for (Integer i = 0; i < n; i++) {
                if (docs[i].commonCase == true && content[i] >= PRIORITY_TAU_CONTENT
                        && gateAdmits(sem[i], lex[i])) {
                    admitted.add(i);
                }
            }
        }
        // Boost at most priorityMaxPromo admitted cases, preferring the strongest base matches.
        Integer maxPromo = (cfg.priorityMaxPromo == null || cfg.priorityMaxPromo < 0)
            ? PRIORITY_MAX_PROMO_DEFAULT : cfg.priorityMaxPromo;
        Set<Integer> boostedSet = new Set<Integer>();
        if (!admitted.isEmpty() && maxPromo > 0) {
            List<Integer> byBase = sortIndicesByValueDesc(admitted, base);
            for (Integer i = 0; i < byBase.size() && boostedSet.size() < maxPromo; i++) {
                boostedSet.add(byBase[i]);
            }
        }

        List<Double> boostedVal = new List<Double>();
        for (Integer i = 0; i < n; i++) {
            Double factor = boostedSet.contains(i) ? PRIORITY_WEIGHT : 1.0;
            boostedVal.add(factor * base[i]);
        }

        // No-leapfrog guard: a boosted common case may win a near-tie but never outscore a doc whose
        // calibrated content is materially higher.
        for (Integer i : boostedSet) {
            Double ceilVal = -1;
            for (Integer j = 0; j < n; j++) {
                if (j == i) { continue; }
                if (content[j] > content[i] + PRIORITY_LEAPFROG_MARGIN) {
                    if (ceilVal < 0 || boostedVal[j] < ceilVal) { ceilVal = boostedVal[j]; }
                }
            }
            if (ceilVal >= 0 && boostedVal[i] >= ceilVal) {
                boostedVal[i] = ceilVal * 0.9999; // sit just under the clearly-better doc
            }
        }

        // Normalize relative to the top fused value (raw RRF values are tiny, ~1/k) so selectAdaptive's
        // relative floor / cluster gap behave as on a [0,1] scale.
        Double maxVal = 0;
        for (Integer i = 0; i < n; i++) { if (boostedVal[i] > maxVal) { maxVal = boostedVal[i]; } }
        if (maxVal <= 0) { maxVal = 1; }
        for (Integer i = 0; i < n; i++) {
            Double norm = boostedVal[i] / maxVal;
            if (norm < 0) { norm = 0; }
            docs[i].score = Decimal.valueOf(norm).setScale(4, System.RoundingMode.HALF_UP);
        }
    }

    /** Gate ('either' mode): cosine >= tauSem OR lexical >= tauLex; lexical-only when cosine is N/A. */
    private static Boolean gateAdmits(Double cosine, Double lexical) {
        Boolean hasSem = (cosine != null && cosine > -1);
        Boolean lexOk = (lexical != null && lexical >= PRIORITY_TAU_LEX);
        if (!hasSem) { return lexOk; }
        return (cosine >= PRIORITY_TAU_SEM) || lexOk;
    }

    private static Double recip(Integer rank, Double k) {
        if (rank == null || rank <= 0) { return 0; }
        return 1.0 / (k + rank);
    }

    /**
     * Dense-rank a value list, returning 1-based ranks parallel to the input (highest value = rank 1).
     * Ties get consecutive ranks in stable input order (deterministic). If `skipBelow` is non-null, values
     * <= skipBelow are treated as "not in the list" and get rank 0 (they contribute nothing to RRF).
     */
    private static List<Integer> rankDesc(List<Double> values, Double skipBelow) {
        Integer n = values.size();
        List<Integer> idx = new List<Integer>();
        for (Integer i = 0; i < n; i++) {
            if (skipBelow == null || values[i] > skipBelow) { idx.add(i); }
        }
        // simple selection sort by value desc, stable on ties (small n: pool <= poolLimit ~40)
        for (Integer a = 0; a < idx.size(); a++) {
            Integer best = a;
            for (Integer b = a + 1; b < idx.size(); b++) {
                if (values[idx[b]] > values[idx[best]]) { best = b; }
            }
            if (best != a) { Integer t = idx[a]; idx[a] = idx[best]; idx[best] = t; }
        }
        List<Integer> ranks = new List<Integer>();
        for (Integer i = 0; i < n; i++) { ranks.add(0); }
        for (Integer r = 0; r < idx.size(); r++) { ranks[idx[r]] = r + 1; }
        return ranks;
    }

    private static List<Integer> sortIndicesByValueDesc(List<Integer> subset, List<Double> values) {
        List<Integer> out = new List<Integer>(subset);
        for (Integer a = 0; a < out.size(); a++) {
            Integer best = a;
            for (Integer b = a + 1; b < out.size(); b++) {
                if (values[out[b]] > values[out[best]]) { best = b; }
            }
            if (best != a) { Integer t = out[a]; out[a] = out[best]; out[best] = t; }
        }
        return out;
    }

    // Trust ladder spanning both source-type vocabularies (label-convention + AI-classifier values).
    private static Decimal trustWeight(String src) {
        if (src == 'canned' || src == 'official') { return 1.0; }
        if (src == 'tips' || src == 'tribal') { return 0.75; }
        if (src == 'unsorted') { return 0.5; }
        if (src == 'draft' || src == 'internal_ops') { return 0.45; }
        return 0.4; // query / null / unknown
    }

    // Confidence reflects how well the TOP doc matches, never which tier surfaced it.
    @TestVisible
    private static String classifyConfidence(Decimal topScore, Config cfg) {
        if (topScore == null || topScore <= 0) { return 'NONE'; }
        if (topScore >= cfg.goodScore) { return 'HIGH'; }
        if (topScore >= cfg.mediumScore) { return 'MEDIUM'; }
        return 'LOW';
    }

    private static Candidate toCandidate(Support_Solution__c s, Integer tier) {
        Candidate c = new Candidate();
        c.solutionId = s.Id;
        c.name = s.Name;
        c.product = s.Product__c;
        c.sourceType = s.Source_Type__c;
        c.visibility = s.Visibility__c;
        c.solutionType = s.Solution_Type__c;
        c.commonCase = (s.Common_Case__c == true);
        c.hasRequiredDisclaimer = s.Has_Required_Disclaimer__c;
        c.url = s.Confluence_URL__c;
        c.confluencePageId = s.Confluence_Page_Id__c;
        c.snippet = snippet(s.Body__c, 300);
        c.tier = tier;
        return c;
    }

    private static String snippet(String body, Integer max) {
        if (String.isBlank(body)) { return ''; }
        String oneLine = body.replaceAll('\\s+', ' ').trim();
        return oneLine.length() > max ? oneLine.substring(0, max) + '...' : oneLine;
    }

    private static Config loadConfig() {
        Config c = new Config();
        Support_Draft_Setting__mdt s = Support_Draft_Setting__mdt.getInstance('Default');
        if (s != null) {
            if (s.Retrieval_Tier2_Pool_Limit__c != null) { c.poolLimit = (Integer) s.Retrieval_Tier2_Pool_Limit__c; }
            if (s.Retrieval_Max_Candidates__c != null) { c.maxCandidates = (Integer) s.Retrieval_Max_Candidates__c; }
            if (s.Retrieval_Good_Match_Score__c != null) { c.goodScore = s.Retrieval_Good_Match_Score__c; }
            if (s.Retrieval_Medium_Match_Score__c != null) { c.mediumScore = s.Retrieval_Medium_Match_Score__c; }
            if (s.Retrieval_Select_Abs_Floor__c != null) { c.selectAbsFloor = s.Retrieval_Select_Abs_Floor__c.doubleValue(); }
            if (s.Retrieval_Select_Rel_Frac__c != null) { c.selectRelFrac = s.Retrieval_Select_Rel_Frac__c.doubleValue(); }
            if (s.Retrieval_Cluster_Gap__c != null) { c.clusterGap = s.Retrieval_Cluster_Gap__c.doubleValue(); }
            if (s.Retrieval_Embedding_Enabled__c != null) { c.embeddingEnabled = s.Retrieval_Embedding_Enabled__c; }
            if (!String.isBlank(s.Retrieval_Embedding_Model__c)) { c.embeddingModel = s.Retrieval_Embedding_Model__c; }
            if (s.Retrieval_Embedding_Weight__c != null) { c.embeddingWeight = s.Retrieval_Embedding_Weight__c; }
            if (s.Retrieval_Embedding_Sim_Floor__c != null) { c.embeddingSimFloor = s.Retrieval_Embedding_Sim_Floor__c; }
            if (s.Retrieval_Embedding_Sim_Ceil__c != null) { c.embeddingSimCeil = s.Retrieval_Embedding_Sim_Ceil__c; }
            if (s.Retrieval_Priority_Enabled__c != null) { c.priorityEnabled = s.Retrieval_Priority_Enabled__c; }
            if (s.Retrieval_Query_Distill_Enabled__c != null) { c.queryDistillEnabled = s.Retrieval_Query_Distill_Enabled__c; }
            if (!String.isBlank(s.Retrieval_Query_Distill_Model__c)) { c.queryDistillModel = s.Retrieval_Query_Distill_Model__c; }
            if (s.Retrieval_Distill_Trigger_Score__c != null) { c.distillTriggerScore = s.Retrieval_Distill_Trigger_Score__c.doubleValue(); }
            if (s.Retrieval_Lexical_Floor_Frac__c != null) { c.lexicalFloorFrac = s.Retrieval_Lexical_Floor_Frac__c.doubleValue(); }
            if (s.Retrieval_Distill_Accept_Margin__c != null) { c.distillAcceptMargin = s.Retrieval_Distill_Accept_Margin__c.doubleValue(); }
        }
        if (Test.isRunningTest()) {
            if (testForceEmbedding != null) { c.embeddingEnabled = testForceEmbedding; }
            if (testForcePriorityEnabled != null) { c.priorityEnabled = testForcePriorityEnabled; }
            if (testForcePriorityMaxPromo != null) { c.priorityMaxPromo = testForcePriorityMaxPromo; }
            if (testForceQueryDistill != null) { c.queryDistillEnabled = testForceQueryDistill; }
            if (testForceLexicalFloorFrac != null) { c.lexicalFloorFrac = testForceLexicalFloorFrac; }
            if (testForceDistillAcceptMargin != null) { c.distillAcceptMargin = testForceDistillAcceptMargin; }
        }
        return c;
    }
}
