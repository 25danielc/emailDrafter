/**
 * The Support_Solution__c record layer: source-agnostic idempotent ingestion (keyed on the
 * Confluence_Page_Id__c external id), markup/security stripping at the single universal write seam,
 * and the async embedding backfill queueable. Every ingestion source writes through here:
 * HelpSdocsConnector (the docs-site sync), CaseSeedImporter (the common-case CSV), CaseMiningJob.
 */
public with sharing class SupportSolutionStore {

    // ---- ingestion ----

    public class PageInput {
        public String pageId;     // required - external id / idempotency key
        public String title;      // -> Name (truncated to 80)
        public String htmlBody;   // raw markdown/HTML -> stripped into Body__c
        public String url;
        public String sourceType;
        public String product;
        public String keywords;   // -> Keywords__c (truncated to 255)
        public Boolean isActive;  // null defaults to true

        // Blank/null visibility/solutionType default to the safe side (agent_only / explainer) at upsert.
        public String visibility;
        public String solutionType;
        public Boolean hasRequiredDisclaimer;
        public String requiredDisclaimerText;
        public String sourceSpaceKey;

        // Classifier axes; not persisted — carried for the connector's dry-run preview and keyword building.
        public String audience;
        public String contentFormat;
        public String topicArea;
        public Decimal visibilityConfidence;

        public Boolean commonCase;            // -> Common_Case__c (priority-eligible; null -> false)

        public PageInput() {}

        public PageInput(String pageId, String title, String htmlBody, String url,
                         String sourceType, String product, String keywords) {
            this.pageId = pageId;
            this.title = title;
            this.htmlBody = htmlBody;
            this.url = url;
            this.sourceType = sourceType;
            this.product = product;
            this.keywords = keywords;
            this.isActive = true;
        }
    }

    public class IngestionResult {
        public Integer processed = 0;
        public Integer failed = 0;
        public List<String> errors = new List<String>();
        // Non-fatal advisories (e.g. residual directive content forced to agent_only).
        public List<String> warnings = new List<String>();
    }

    /** Idempotent bulk upsert; blank-pageId rows are reported as failures, never silently dropped. */
    public static IngestionResult upsertPages(List<PageInput> pages) {
        IngestionResult result = new IngestionResult();
        if (pages == null || pages.isEmpty()) {
            return result;
        }

        List<Support_Solution__c> toUpsert = new List<Support_Solution__c>();
        Datetime now = Datetime.now();

        for (PageInput p : pages) {
            if (p == null || String.isBlank(p.pageId)) {
                result.failed++;
                result.errors.add('Skipped page with blank pageId (title=' +
                    (p == null ? 'null' : p.title) + ')');
                continue;
            }
            Support_Solution__c rec = new Support_Solution__c();
            rec.Confluence_Page_Id__c = p.pageId.trim();
            rec.Name = truncate(String.isBlank(p.title) ? p.pageId : p.title, 80);
            rec.Body__c = stripHtml(p.htmlBody);
            rec.Confluence_URL__c = p.url;
            rec.Source_Type__c = p.sourceType;
            rec.Product__c = p.product;
            rec.Keywords__c = truncate(p.keywords, 255);
            rec.Active__c = (p.isActive == null) ? true : p.isActive;
            rec.Visibility__c = String.isBlank(p.visibility)
                ? SupportDraftVocab.VIS_AGENT_ONLY : p.visibility.trim();
            rec.Solution_Type__c = String.isBlank(p.solutionType) ? 'explainer' : p.solutionType.trim();
            rec.Has_Required_Disclaimer__c = (p.hasRequiredDisclaimer == null) ? false : p.hasRequiredDisclaimer;
            rec.Required_Disclaimer_Text__c = p.requiredDisclaimerText;
            rec.Source_Space_Key__c = truncate(p.sourceSpaceKey, 40);
            rec.Common_Case__c = (p.commonCase == null) ? false : p.commonCase;
            rec.Last_Synced__c = now;
            // Recurrence guard: stripHtml removes the known GitBook "Agent Instructions" trailer, but a
            // novel injection shape could survive. Never let residual directive content reach the drafting
            // model as customer_safe — withhold it to agent_only and surface a warning.
            if (rec.Visibility__c == SupportDraftVocab.VIS_CUSTOMER_SAFE
                    && containsAgentDirective(rec.Body__c)) {
                rec.Visibility__c = SupportDraftVocab.VIS_AGENT_ONLY;
                result.warnings.add('Page ' + rec.Confluence_Page_Id__c +
                    ' -> residual agent-directive content; visibility forced to agent_only');
            }
            toUpsert.add(rec);
        }

        if (!toUpsert.isEmpty()) {
            // allOrNone=false: one malformed row must not roll back the whole load.
            List<Database.UpsertResult> srs =
                Database.upsert(toUpsert, Support_Solution__c.Confluence_Page_Id__c, false);
            for (Integer i = 0; i < srs.size(); i++) {
                if (srs[i].isSuccess()) {
                    result.processed++;
                } else {
                    result.failed++;
                    String msg = '';
                    for (Database.Error e : srs[i].getErrors()) {
                        msg += e.getStatusCode() + ': ' + e.getMessage() + '; ';
                    }
                    result.errors.add('Page ' + toUpsert[i].Confluence_Page_Id__c + ' -> ' + msg);
                }
            }
        }
        return result;
    }

    /** Removed source pages get Active__c=false (deactivate, not delete — keeps the audit trail). */
    public static IngestionResult deactivatePages(Set<String> pageIds) {
        IngestionResult result = new IngestionResult();
        if (pageIds == null || pageIds.isEmpty()) {
            return result;
        }
        List<Support_Solution__c> recs = [
            SELECT Id, Active__c FROM Support_Solution__c
            WHERE Confluence_Page_Id__c IN :pageIds AND Active__c = true
        ];
        for (Support_Solution__c r : recs) {
            r.Active__c = false;
        }
        if (!recs.isEmpty()) {
            List<Database.SaveResult> srs = Database.update(recs, false);
            for (Integer i = 0; i < srs.size(); i++) {
                if (srs[i].isSuccess()) {
                    result.processed++;
                } else {
                    result.failed++;
                    String msg = '';
                    for (Database.Error e : srs[i].getErrors()) {
                        msg += e.getStatusCode() + ': ' + e.getMessage() + '; ';
                    }
                    result.errors.add('Deactivate ' + recs[i].Id + ' -> ' + msg);
                }
            }
        }
        return result;
    }

    /**
     * Strip markup to clean text: hyperlinks become "text (url)", images collapse to an [image] marker,
     * block tags become line breaks, remaining tags/macros are removed, entities decoded.
     */
    public static String stripHtml(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String text = html;
        // SECURITY: neutralize prompt-injection / "agent instruction" directives BEFORE any other
        // processing, so they never reach Body__c, the embedding source (docText), or the drafting
        // prompt. Runs at the single universal write seam, covering every ingestion source.
        text = stripAgentDirectives(text);
        // Protect code spans BEFORE any tag stripping: fenced ``` blocks, <pre>/<code> bodies, and
        // inline `...` spans carry real payload — S-Docs template syntax (<column>, lineitems tags),
        // Apex generics (List<ContentDistribution>), error strings — whose angle-bracketed tokens the
        // blanket tag strip below would otherwise delete (measured corpus bug, 2026-07-21 eval:
        // gutted DOCX-table and related-list docs caused ungrounded/degraded drafts).
        List<String> codeSpans = new List<String>();
        text = protectDelimited(text, '```', '```', false, codeSpans, false);
        text = protectDelimited(text, '<pre', '</pre>', true, codeSpans, true);
        text = protectDelimited(text, '<code', '</code>', true, codeSpans, true);
        text = protectDelimited(text, '`', '`', false, codeSpans, false);
        text = text.replaceAll('(?is)<ac:image\\b.*?</ac:image>', ' [image] ');
        text = text.replaceAll('(?is)<ac:image\\b[^>]*/>', ' [image] ');
        text = text.replaceAll('(?i)<img\\b[^>]*>', ' [image] ');
        text = inlineLinks(text);
        text = text.replaceAll('(?i)<\\s*(br|/p|/div|/li|/tr|/h[1-6])[^>]*>', '\n');
        text = text.replaceAll('<[^>]+>', ' ');
        text = decodeEntities(text);
        text = text.replaceAll('[ \\t]+', ' ');
        // Blank-line collapse, anchored on \n so every non-newline position fails in O(1) — a
        // leading [ \t\r]* backtracks quadratically per whitespace run, and the original
        // '(\\s*\\n\\s*){2,}' was exponentially ambiguous ('Regex too complicated' class).
        text = text.replaceAll('\\n(?:[ \\t\\r]*\\n)+', '\n\n');
        for (Integer i = codeSpans.size() - 1; i >= 0; i--) {
            text = text.replace('@@CODESPAN' + i + '@@', codeSpans[i]);
        }
        return text.trim();
    }

    /** Replace every open..close delimited span with an indexed placeholder and stash the span for
     *  later restore. indexOf-based on purpose: lazy-dotall regex over a large page with an unpaired
     *  delimiter backtracks quadratically and threw 'Regex too complicated' on the 07-22 re-ingest.
     *  htmlTag: open is a tag prefix ('<pre') — the span starts at the tag, and the wrapper tags are
     *  dropped + entities decoded so the payload is stored as literal text. An unpaired opener is
     *  left in place (no span). Single-backtick spans never cross a line break. */
    private static String protectDelimited(String text, String open, String close,
            Boolean htmlTag, List<String> store, Boolean unwrapHtml) {
        String lower = htmlTag ? text.toLowerCase() : null;
        String out = '';
        Integer pos = 0;
        while (pos < text.length()) {
            Integer start = htmlTag ? lower.indexOf(open, pos) : text.indexOf(open, pos);
            if (start == -1) { break; }
            Integer contentStart = start + open.length();
            if (htmlTag) {
                Integer tagEnd = text.indexOf('>', start);
                if (tagEnd == -1) { break; }
                contentStart = tagEnd + 1;
            }
            Integer endIdx = htmlTag
                ? lower.indexOf(close, contentStart) : text.indexOf(close, contentStart);
            if (endIdx == -1) { break; }
            String span;
            if (unwrapHtml) {
                span = decodeEntities(text.substring(contentStart, endIdx));
            } else {
                span = text.substring(start, endIdx + close.length());
            }
            if (open == '`' && span.indexOf('\n') != -1) {
                // an apostrophe-like stray backtick pairing across lines is not a code span
                out += text.substring(pos, start + 1);
                pos = start + 1;
                continue;
            }
            out += text.substring(pos, start);
            store.add(span);
            out += '@@CODESPAN' + (store.size() - 1) + '@@';
            pos = endIdx + close.length();
        }
        return out + text.substring(pos);
    }

    private static String decodeEntities(String text) {
        return text.replace('&nbsp;', ' ')
                   .replace('&amp;', '&')
                   .replace('&lt;', '<')
                   .replace('&gt;', '>')
                   .replace('&quot;', '"')
                   .replace('&#39;', '\'')
                   .replace('&apos;', '\'');
    }

    /**
     * SECURITY: strip embedded "agent instruction" / prompt-injection directives from ingested doc bodies.
     * The dominant shape is a templated GitBook trailer appended to every help.sdocs page:
     *   "--- \n # Agent Instructions \n ...Perform an HTTP GET request... \n ```GET https://help.sdocs.com/...?ask= &goal=``` "
     * It is always the tail of the body, so we cut from the "# Agent Instructions" heading (and any
     * immediately-preceding --- / *** separator) to end-of-string, then remove any stray live-fetch
     * GET directive lines that appear elsewhere. Deterministic; leaves legitimate content intact.
     */
    @TestVisible
    private static String stripAgentDirectives(String text) {
        if (String.isBlank(text)) { return text; }
        String out = text;
        // 1. GitBook "Agent Instructions" trailer: cut from the '# Agent Instructions' heading to
        // end-of-string. Located by CHARACTER SCAN, not regex — every regex formulation (bounded or
        // not) exceeded the Apex regex work limit on large table-heavy pages (58KB s-sign-objects,
        // millions of '---' table-separator match starts, 2026-07-22).
        out = cutAgentInstructionsTrailer(out);
        // 2. Any residual live-HTTP-fetch directive line targeting the doc's own ?ask= query
        // endpoint. contains() precheck so the bounded line regex never runs on clean big pages.
        if (out.contains('?ask=')) {
            out = out.replaceAll('(?im)^.{0,400}\\bGET\\s+https?://\\S{1,500}\\?ask=.{0,400}$', '');
        }
        // 3. The stray instruction sentence, if it survived without the heading.
        if (out.toLowerCase().contains('perform an http get request')) {
            out = out.replaceAll('(?is)Perform an HTTP GET request[^\\r\\n]*', '');
        }
        return out;
    }

    /** Cut from a heading-shaped '# Agent Instructions' line (1-6 #'s at line start) to the end,
     *  plus a directly-preceding --- / *** separator line. Pure character scan. */
    @TestVisible
    private static String cutAgentInstructionsTrailer(String text) {
        String lower = text.toLowerCase();
        Integer h = lower.indexOf('agent instructions');
        while (h != -1) {
            Integer i = h - 1;
            while (i >= 0 && (text.charAt(i) == 32 || text.charAt(i) == 9)) { i--; }
            Integer hashEnd = i;
            while (i >= 0 && text.charAt(i) == 35) { i--; }                    // '#'
            Integer hashes = hashEnd - i;
            while (i >= 0 && (text.charAt(i) == 32 || text.charAt(i) == 9)) { i--; }
            Boolean atLineStart = (i < 0) || text.charAt(i) == 10 || text.charAt(i) == 13;
            if (hashes >= 1 && hashes <= 6 && atLineStart) {
                Integer cut = (i < 0) ? 0 : i;
                // trim trailing whitespace, then a bare --- / *** separator line, then whitespace
                cut = rstripTo(text, cut);
                Integer sepEnd = cut;
                Integer sc = 0;
                while (cut > 0 && (text.charAt(cut - 1) == 45 || text.charAt(cut - 1) == 42)) { cut--; sc++; }
                if (sc >= 3) {
                    Integer j = cut;
                    while (j > 0 && (text.charAt(j - 1) == 32 || text.charAt(j - 1) == 9)) { j--; }
                    if (j == 0 || text.charAt(j - 1) == 10 || text.charAt(j - 1) == 13) {
                        cut = rstripTo(text, j);
                    } else {
                        cut = sepEnd;
                    }
                } else {
                    cut = sepEnd;
                }
                return text.substring(0, cut);
            }
            h = lower.indexOf('agent instructions', h + 1);
        }
        return text;
    }

    /** Index after the last non-whitespace char at or before end (scanning back from end). */
    private static Integer rstripTo(String text, Integer endExclusive) {
        Integer e = endExclusive;
        while (e > 0) {
            Integer c = text.charAt(e - 1);
            if (c == 32 || c == 9 || c == 10 || c == 13) { e--; } else { break; }
        }
        return e;
    }

    /**
     * Detect residual agent-directive / live-fetch content for the ingestion recurrence guard.
     * Returns true if a novel injection shape survived stripAgentDirectives.
     */
    @TestVisible
    private static Boolean containsAgentDirective(String text) {
        if (String.isBlank(text)) { return false; }
        String low = text.toLowerCase();
        if (low.contains('agent instructions')) { return true; }
        if (low.contains('perform an http get request')) { return true; }
        if (Pattern.compile('(?i)\\bget\\s+https?://\\S+\\?ask=').matcher(text).find()) { return true; }
        return false;
    }

    /** <a href="url">text</a> -> "text (url)"; keeps just the url when the text already equals it.
     *  Quantifiers bounded: an unpaired '<a' with unbounded lazy content scans to EOF per
     *  occurrence (quadratic — the 'Regex too complicated' class of failure). */
    private static String inlineLinks(String html) {
        Pattern p = Pattern.compile('(?is)<a\\b[^>]{0,400}?href="([^"]{0,600})"[^>]{0,400}>(.{0,1500}?)</a>');
        Matcher m = p.matcher(html);
        String result = '';
        Integer last = 0;
        while (m.find()) {
            result += html.substring(last, m.start());
            String href = m.group(1).trim();
            String linkText = m.group(2).replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
            String repl;
            if (String.isBlank(href)) {
                repl = linkText;
            } else if (String.isBlank(linkText) || linkText.equalsIgnoreCase(href)) {
                repl = href;
            } else {
                repl = linkText + ' (' + href + ')';
            }
            result += repl;
            last = m.end();
        }
        result += html.substring(last);
        return result;
    }

    private static String truncate(String s, Integer max) {
        if (s == null) {
            return null;
        }
        return s.length() > max ? s.substring(0, max) : s;
    }

    // ---- embedding backfill (async) ----
    // Chained Queueable that fills Embedding__c on active un-embedded rows, batched per callout so bulk
    // ingestion never couples to the model. Doc + query vectors must share the mdt embedding model.
    // Resumable: re-running targets only un-embedded rows; null out Embedding__c to force a re-embed.

    @TestVisible private static Integer BATCH = 20;
    @TestVisible private static Integer MAX_CALLOUTS = 4;
    private static final Integer MAX_TEXT_CHARS = 3000; // bound tokens/request; title+keywords+body prefix
    private static final Integer MAX_DEPTH = 100;       // chain backstop (100*80 = 8000 docs)

    public static Id enqueue() {
        return System.enqueueJob(new SupportSolutionEmbedder());
    }

    @TestVisible
    private static String docText(Support_Solution__c s) {
        String t = (s.Name == null ? '' : s.Name)
            + '\n' + (s.Keywords__c == null ? '' : s.Keywords__c)
            + '\n' + (s.Body__c == null ? '' : s.Body__c);
        t = t.trim();
        return t.length() > MAX_TEXT_CHARS ? t.substring(0, MAX_TEXT_CHARS) : t;
    }

    private static String embeddingModel() {
        Support_Draft_Setting__mdt cfg = Support_Draft_Setting__mdt.getInstance('Default');
        if (cfg != null && !String.isBlank(cfg.Retrieval_Embedding_Model__c)) {
            return cfg.Retrieval_Embedding_Model__c;
        }
        return SupportDraftVocab.MODEL_EMBEDDING_DEFAULT;
    }

    public class SupportSolutionEmbedder implements Queueable, Database.AllowsCallouts {

        private final Integer depth;

        public SupportSolutionEmbedder() { this.depth = 0; }
        private SupportSolutionEmbedder(Integer depth) { this.depth = depth; }

        public void execute(QueueableContext ctx) {
            if (depth >= MAX_DEPTH) {
                System.debug(LoggingLevel.WARN, 'SupportSolutionEmbedder hit MAX_DEPTH; stopping. '
                    + 'Re-enqueue to continue.');
                return;
            }

            Integer want = BATCH * MAX_CALLOUTS;
            // Filter on Embedding_Synced__c — Embedding__c is a Long Text Area and can't be filtered.
            List<Support_Solution__c> rows = [
                SELECT Id, Name, Keywords__c, Body__c
                FROM Support_Solution__c
                WHERE Active__c = true AND Embedding_Synced__c = false AND Source_Type__c != 'query'
                LIMIT :want
            ];
            if (rows.isEmpty()) { return; } // backlog drained

            String model = embeddingModel();
            SupportRetrievalService.EmbeddingClient client = SupportRetrievalService.embeddingClient();

            List<Support_Solution__c> toUpdate = new List<Support_Solution__c>();
            Integer i = 0;
            Integer callouts = 0;
            while (i < rows.size() && callouts < MAX_CALLOUTS) {
                List<Support_Solution__c> chunk = new List<Support_Solution__c>();
                List<String> texts = new List<String>();
                for (Integer j = i; j < rows.size() && chunk.size() < BATCH; j++) {
                    chunk.add(rows[j]);
                    texts.add(docText(rows[j]));
                }
                i += chunk.size();
                callouts++;

                List<List<Double>> vecs;
                try {
                    vecs = client.embed(model, texts);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'Embedding callout failed; stopping run: ' + e.getMessage());
                    break; // leave the rest null for the next run
                }
                if (vecs == null || vecs.size() != chunk.size()) {
                    System.debug(LoggingLevel.ERROR, 'Embedding response shape mismatch; stopping run.');
                    break;
                }
                for (Integer k = 0; k < chunk.size(); k++) {
                    if (vecs[k] == null || vecs[k].isEmpty()) { continue; } // leave unsynced -> retried next run
                    chunk[k].Embedding__c = JSON.serialize(vecs[k]);
                    chunk[k].Embedding_Synced__c = true;
                    toUpdate.add(chunk[k]);
                }
            }

            Integer updated = 0;
            if (!toUpdate.isEmpty()) {
                // allOrNone=false: one bad row never discards a whole batch of good vectors.
                for (Database.SaveResult sr : Database.update(toUpdate, false)) {
                    if (sr.isSuccess()) { updated++; }
                }
            }

            // Chain only if we made progress AND likely have more (a full fetch). Stopping when updated==0
            // prevents an infinite loop when the model is unavailable (rows would stay null forever).
            if (updated > 0 && rows.size() == want && !Test.isRunningTest()) {
                System.enqueueJob(new SupportSolutionEmbedder(depth + 1));
            }
        }
    }
}
