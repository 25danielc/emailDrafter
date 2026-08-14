/**
 * The help.sdocs.com connector: enumerates section sitemaps, fetches each page's markdown
 * (`<url>.md`), classifies it with one ModelsAPI call per page, and upserts through
 * SupportSolutionStore. Visibility is FORCED customer_safe for this source (the whole corpus is
 * published docs); the classifier's other axes still feed retrieval/audit. Sync runs dry-run
 * (preview, no writes) by default; the full corpus commits via HelpSdocsSyncQueueable.
 */
public with sharing class HelpSdocsConnector {

    public class HelpSdocsException extends Exception {}

    /** Product-doc sections to enumerate. Changelog is excluded (release notes, low drafting value). */
    public static final List<String> DEFAULT_SECTIONS =
        new List<String>{ 'quick-start', 'sdocs', 's-sign', 'developer-hub' };

    /** A page URL discovered in a sitemap, before its body is fetched. */
    public class UrlRef {
        public String url;
        public String section;        // quick-start | sdocs | s-sign | developer-hub
        public Datetime lastModified; // from <lastmod>, or null
        public UrlRef() {}
        public UrlRef(String url, String section, Datetime lastModified) {
            this.url = url; this.section = section; this.lastModified = lastModified;
        }
    }

    public class DocPage {
        public String id;             // URL path (external id / idempotency key), e.g. s-sign/.../slug
        public String url;
        public String section;
        public String title;          // first H1, or the slug as a fallback
        public String markdown;       // cleaned markdown body (boilerplate stripped)
        public Datetime lastModified;
    }

    public interface Transport {
        String get(String absoluteUrl);
    }

    @TestVisible
    private static Transport http = new RestTransport();

    private static final String BASE = 'https://help.sdocs.com';

    public static List<UrlRef> listUrls(List<String> sections) {
        List<String> secs = (sections == null || sections.isEmpty()) ? DEFAULT_SECTIONS : sections;
        List<UrlRef> out = new List<UrlRef>();
        for (String sec : secs) {
            String xml = http.get(BASE + '/' + sec.trim() + '/sitemap-pages.xml');
            out.addAll(parseSitemap(xml, sec.trim()));
        }
        return out;
    }

    public static DocPage fetchPage(UrlRef ref) {
        String md = cleanMarkdown(http.get(ref.url + '.md'));
        DocPage pg = new DocPage();
        pg.url = ref.url;
        pg.section = ref.section;
        pg.lastModified = ref.lastModified;
        pg.id = pathOf(ref.url);
        pg.markdown = md;
        pg.title = firstNonBlank(firstHeading(md), slugOf(ref.url));
        return pg;
    }

    @TestVisible
    private static List<UrlRef> parseSitemap(String xml, String section) {
        List<UrlRef> out = new List<UrlRef>();
        if (String.isBlank(xml)) { return out; }
        // Match each <loc>...</loc>, then look for a <lastmod> that follows it within the same <url>.
        Matcher m = Pattern.compile('(?is)<loc>\\s*(.*?)\\s*</loc>(.*?)(?=<loc>|</urlset>|$)').matcher(xml);
        while (m.find()) {
            String loc = m.group(1);
            if (String.isBlank(loc)) { continue; }
            UrlRef ref = new UrlRef();
            ref.url = loc.trim();
            ref.section = section;
            Matcher lm = Pattern.compile('(?is)<lastmod>\\s*(.*?)\\s*</lastmod>').matcher(m.group(2));
            if (lm.find()) {
                try {
                    ref.lastModified =
                        (Datetime) JSON.deserialize('"' + lm.group(1).trim() + '"', Datetime.class);
                } catch (Exception e) { /* leave null on odd formats */ }
            }
            out.add(ref);
        }
        return out;
    }

    public class RestTransport implements Transport {
        public String get(String absoluteUrl) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(absoluteUrl);
            req.setMethod('GET');
            req.setHeader('Accept', 'text/markdown, application/xml, text/plain, */*');
            req.setTimeout(120000);

            HttpResponse res = new System.Http().send(req);
            if (res.getStatusCode() != 200) {
                throw new HelpSdocsException('help.sdocs GET failed: HTTP '
                    + res.getStatusCode() + ' - ' + absoluteUrl);
            }
            return res.getBody();
        }
    }

    // ---- markdown / url helpers ----

    /**
     * Normalize raw GitBook markdown: drop the boilerplate blockquote, strip Liquid macros (keeping
     * inner text), decode numeric entities, unescape list/table punctuation. {{...}} is left alone —
     * those are real S-Docs merge-field examples, not macros.
     */
    @TestVisible
    private static String cleanMarkdown(String md) {
        if (String.isBlank(md)) { return ''; }
        String out = md;
        out = out.replaceFirst('(?im)^>\\s*For the complete documentation index.*(\\r?\\n)+', '');
        // Liquid macro strip, bounded: an unpaired {% with unbounded lazy content scans to EOF per
        // occurrence — quadratic on template-syntax pages ('Regex too complicated').
        out = out.replaceAll('(?s)\\{%.{0,2000}?%\\}', '');
        out = decodeNumericEntities(out);                     // &#124; -> |
        out = out.replaceAll('\\\\([.|\\-])', '$1');          // 1\. -> 1.   \| -> |
        // Blank-line collapse, anchored on \n so every non-newline position fails in O(1). A
        // leading [ \t\r]* here is quadratic per whitespace run (this markdown pads table cells
        // with thousands of spaces — 'Regex too complicated' on developer-hub/s-sign-objects);
        // the old (\s*\n\s*){3,} was exponentially worse.
        out = out.replaceAll('\\n(?:[ \\t\\r]*\\n){2,}', '\n\n');
        return out.trim();
    }

    @TestVisible
    private static String decodeNumericEntities(String s) {
        if (String.isBlank(s) || !s.contains('&#')) { return s; }
        Matcher m = Pattern.compile('&#([xX]?)([0-9a-fA-F]+);').matcher(s);
        String result = '';
        Integer last = 0;
        while (m.find()) {
            result += s.substring(last, m.start());
            try {
                Integer code = String.isBlank(m.group(1))
                    ? Integer.valueOf(m.group(2)) : hexToInt(m.group(2));
                result += String.fromCharArray(new List<Integer>{ code });
            } catch (Exception e) {
                result += m.group(0); // malformed entity -> leave verbatim
            }
            last = m.end();
        }
        result += s.substring(last);
        return result;
    }

    private static Integer hexToInt(String hex) {
        Integer val = 0;
        String digits = '0123456789abcdef';
        for (Integer i = 0; i < hex.length(); i++) {
            Integer d = digits.indexOf(hex.substring(i, i + 1).toLowerCase());
            if (d < 0) { throw new HelpSdocsException('bad hex'); }
            val = val * 16 + d;
        }
        return val;
    }

    @TestVisible
    private static String firstHeading(String md) {
        if (String.isBlank(md)) { return null; }
        Matcher m = Pattern.compile('(?m)^#\\s+(.+?)\\s*$').matcher(md);
        return m.find() ? m.group(1).trim() : null;
    }

    @TestVisible
    private static String pathOf(String url) {
        if (String.isBlank(url)) { return url; }
        String p = url.replaceFirst('(?i)^https?://[^/]+/?', '');
        return p.replaceFirst('/+$', '');
    }

    private static String slugOf(String url) {
        String p = pathOf(url);
        String slug = p.contains('/') ? p.substringAfterLast('/') : p;
        return String.isBlank(slug) ? p : slug.replace('-', ' ').trim();
    }

    private static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : b;
    }

    // ---- classifier: per-page ModelsAPI classification + deterministic visibility gate ----
    // The model proposes; commitVisibility disposes. Out-of-budget/off/test/parse-failure all fall back
    // to a heuristic; axis values are normalized to the deployed restricted-picklist API names.

    public class PageContent {
        public String title;
        public String sectionKey;   // source section / space provenance (biases the product prior)
        public String body;         // raw body (markdown or HTML); stripped before it reaches the prompt
        public List<String> labels = new List<String>();
        public Datetime lastModified;
    }

    // Native model used across the org's Trust-Layer callouts.
    private static final String MODEL_NAME = SupportDraftVocab.MODEL_MINI_DEFAULT;
    // Leave headroom under the per-transaction callout ceiling for pagination/search callouts.
    private static final Integer CALLOUT_BUFFER = 2;
    // Bound the body we send so a huge page can't blow the token/heap budget.
    private static final Integer MAX_BODY_CHARS = 6000;

    private static final Decimal VISIBILITY_FLOOR = 0.80;
    // Strict audience set: relaxing to {customer, agent} would promote agent-voiced product help.
    private static final Set<String> AUDIENCE_ALLOWED = new Set<String>{ 'customer' };

    // Allowed API values per restricted picklist (anything else normalizes to the safe default).
    private static final Set<String> FORMATS = new Set<String>{
        'how_to','troubleshooting','reference','faq','concept','release_note','template','internal_process' };
    private static final Set<String> TRUSTS = new Set<String>{
        'official','draft','internal_ops','tribal','unsorted' };
    private static final Set<String> AUDIENCES = new Set<String>{ 'customer','agent','internal' };
    private static final Set<String> VISIBILITIES = new Set<String>{
        SupportDraftVocab.VIS_CUSTOMER_SAFE, SupportDraftVocab.VIS_AGENT_ONLY,
        SupportDraftVocab.VIS_ESCALATE_ONLY };
    private static final Set<String> TOPICS = new Set<String>{
        'installation_setup','templates_merge_fields','e_signature','integrations','permissions_security',
        'billing_licensing','errors_troubleshooting','api_developer','other' };

    @TestVisible private static Classification mockResult;
    @TestVisible private static String mockRawResponse;

    public class Classification {
        public String product;        // S-Docs | S-Sign | None | Both  (Both is a split signal, not stored)
        public String contentFormat;  // descriptive format (classifier vocab); derives solutionType, or null
        public String sourceType;     // Source_Type__c trust api value, or null
        public String topicArea;      // topic area (classifier vocab); folded into Keywords__c, or null
        public String topicDetail;    // free text <= 80; folded into Keywords__c
        public String audience;       // customer | agent | internal, or null
        public String visibility;     // customer_safe | agent_only | escalate_only, or null
        public Decimal visibilityConfidence;
        public Boolean modelUsed = false;
        public List<String> redFlags = new List<String>();  // internal/leak signals scanned from the body
        public String proposedVisibility;                    // model's pre-gate visibility proposal (audit)
        public Decimal audienceConfidence;                   // model certainty on audience (audit/diagnostics)
        public List<String> keywords = new List<String>();   // 8-10 search terms for retrieval (-> Keywords__c)
    }

    /** Classify one page. Never throws — every failure mode falls back to the keyword heuristic. */
    public static Classification classify(PageContent pg, String defaultProduct, Boolean doClassify) {
        if (mockResult != null) { return mockResult; }
        String body = (pg == null || pg.body == null) ? '' : pg.body;

        if (doClassify != false && hasCalloutBudget()) {
            try {
                String text = SupportSolutionStore.stripHtml(body);
                if (text.length() > MAX_BODY_CHARS) { text = text.substring(0, MAX_BODY_CHARS); }
                String prompt = buildPrompt(pg, text);
                // The live callout is skipped in tests; mockRawResponse drives the real parse path there.
                String raw = (mockRawResponse != null) ? mockRawResponse
                    : (Test.isRunningTest() ? null : callModel(prompt));
                Classification c = parse(raw);
                if (c != null) {
                    c.modelUsed = true;
                    return c;
                }
            } catch (Exception e) {
                System.debug('help.sdocs classifier callout/parse failed, using heuristic: ' + e.getMessage());
            }
        }
        return heuristic(body, defaultProduct);
    }

    public static String solutionTypeFor(String contentFormat) {
        if (contentFormat == 'how_to' || contentFormat == 'troubleshooting') { return 'procedure'; }
        if (contentFormat == 'template') { return 'template'; }
        if (contentFormat == 'reference') { return 'reference'; }
        if (contentFormat == 'faq' || contentFormat == 'concept'
            || contentFormat == 'release_note' || contentFormat == 'internal_process') { return 'explainer'; }
        return null; // unknown -> let the caller's heuristic / upsert default decide
    }

    // ---- model call (the shared Models API transport) ----

    private static String callModel(String promptText) {
        return EinsteinAiClient.chat(MODEL_NAME, promptText);
    }

    private static Boolean hasCalloutBudget() {
        return Limits.getCallouts() < (Limits.getLimitCallouts() - CALLOUT_BUFFER);
    }

    // ---- parse + normalize ----

    @TestVisible
    private static Classification parse(String responseBody) {
        if (String.isBlank(responseBody)) { return null; }
        Map<String, Object> root = EinsteinAiClient.parseModelJson(responseBody);
        if (root == null) { return null; }

        Classification c = new Classification();
        c.product = normProduct(axisValue(root, 'product'));
        c.contentFormat = inSet(slug(axisValue(root, 'format')), FORMATS, null);
        c.sourceType = inSet(slug(axisValue(root, 'trust')), TRUSTS, 'unsorted');
        c.audience = inSet(slug(axisValue(root, 'audience')), AUDIENCES, 'internal');
        c.audienceConfidence = confidenceOf(root.get('audience'));
        c.proposedVisibility = inSet(slug(axisValue(root, 'visibility')), VISIBILITIES,
            SupportDraftVocab.VIS_AGENT_ONLY);
        c.redFlags = strList(root.get('red_flags'));
        c.keywords = normKeywords(strList(root.get('keywords')));

        Map<String, Object> topic = asMap(root.get('topic'));
        if (topic != null) {
            c.topicArea = inSet(slug(str(topic.get('area'))), TOPICS, 'other');
            c.topicDetail = trunc(str(topic.get('detail')), 80);
        } else {
            c.topicArea = 'other';
        }

        c.visibilityConfidence = confidenceOf(root.get('visibility'));
        commitVisibility(c);
        return c;
    }

    /**
     * Deterministic visibility gate: can only DEMOTE a customer_safe proposal, never promote past it;
     * escalate_only is preserved. Same evidence in -> same committed label out, every run.
     */
    @TestVisible
    private static void commitVisibility(Classification c) {
        Boolean safe =
            c.proposedVisibility == SupportDraftVocab.VIS_CUSTOMER_SAFE
            && AUDIENCE_ALLOWED.contains(c.audience)        // strict default {customer}
            && c.product != 'None'
            && c.contentFormat != 'internal_process'
            && (c.redFlags == null || c.redFlags.isEmpty())
            && c.visibilityConfidence != null
            && c.visibilityConfidence >= VISIBILITY_FLOOR;  // confidence floor (carries audience uncertainty)
        c.visibility = safe ? SupportDraftVocab.VIS_CUSTOMER_SAFE
            : (c.proposedVisibility == SupportDraftVocab.VIS_ESCALATE_ONLY
                ? SupportDraftVocab.VIS_ESCALATE_ONLY : SupportDraftVocab.VIS_AGENT_ONLY);
    }

    // ---- heuristic fallback (reproduces pre-AI keyword/regex behavior; keeps existing tests green) ----

    private static Classification heuristic(String body, String defaultProduct) {
        String t = (body == null ? '' : body).toLowerCase();
        Boolean sdoc = t.contains('s-doc') || t.contains('sdocs');
        Boolean ssign = t.contains('s-sign') || t.contains('ssign');
        Classification c = new Classification();
        if (sdoc && ssign) { c.product = 'Both'; }
        else if (sdoc) { c.product = 'S-Docs'; }
        else if (ssign) { c.product = 'S-Sign'; }
        else { c.product = String.isBlank(defaultProduct) ? 'None' : defaultProduct; }
        // Everything else stays null so upsert applies the safe defaults (agent_only / explainer / etc.).
        c.topicArea = null;
        c.audience = null;
        c.visibility = null;
        c.sourceType = null;
        c.modelUsed = false;
        return c;
    }

    // ---- prompt ----

    private static String buildPrompt(PageContent pg, String body) {
        String labels = (pg.labels == null || pg.labels.isEmpty()) ? '(none)' : String.join(pg.labels, ', ');
        return SYSTEM_PROMPT
            + '\n\n=== PAGE ===\n'
            + 'title: ' + safe(pg.title) + '\n'
            + 'section: ' + safe(pg.sectionKey) + '\n'
            + 'existing_labels: ' + labels + '\n'
            + 'last_modified: ' + (pg.lastModified == null ? '' : String.valueOf(pg.lastModified)) + '\n'
            + 'body:\n' + body + '\n'
            + '=== END PAGE ===\n'
            + 'Return ONLY the JSON object.';
    }

    private static String safe(String s) { return s == null ? '' : s; }

    private static final String SYSTEM_PROMPT =
'You are the classification layer in a product-documentation -> Salesforce knowledge ingestion pipeline.\n' +
'For each page you emit ONE strict-JSON classification as EVIDENCE. You do NOT make the final\n' +
'customer_safe decision - a deterministic code gate downstream does, from the fields you emit. Report\n' +
'what the page IS, accurately and conservatively.\n' +
'\n' +
'Default posture: the corpus sits at agent_only. Failing to surface a good page is recoverable; an\n' +
'internal page reaching a customer draft is NOT. When unsure, lower confidence and flag anything internal.\n' +
'Always commit a best guess on every axis - never abstain.\n' +
'\n' +
'Emit EXACTLY these API values (anything else is rejected downstream):\n' +
'\n' +
'product  : "S-Docs" | "S-Sign" | "None" | "Both"\n' +
'  None is first-class and common (training, Slackbot, HR/ops). The section hint may bias product\n' +
'  (s-sign ->S-Sign, sdocs ->S-Docs); cross-cutting sections have NO useful prior - the body dominates.\n' +
'  merge-token/template/doc-generation ->S-Docs; signature/envelope/recipient/e-sign ->S-Sign; neither or\n' +
'  internal/ops/HR/process subject ->None. One product with an incidental mention of the other -> return\n' +
'  the primary (NOT Both) and note "incidental". Both ONLY when the page documents both in separate sections.\n' +
'\n' +
'format   : "how_to" | "troubleshooting" | "reference" | "faq" | "concept" | "release_note" | "template" |\n' +
'           "internal_process". internal_process = how the SUPPORT TEAM or COMPANY operates: case triage,\n' +
'           queue/routing, rules of engagement, escalation, SLA, onboarding/training, tooling, HR,\n' +
'           change-request, runbook, standup. Step-by-step formatting does NOT make a team process a\n' +
'           how_to - if the steps ROUTE/COORDINATE internally, it is internal_process. (otherwise: ordered\n' +
'           steps->how_to; symptom->fix=troubleshooting; field/param tables->reference; Q&A->faq; overview\n' +
'           ->concept; version/changelog->release_note; merge tokens/boilerplate->template.)\n' +
'\n' +
'trust    : "official" | "draft" | "internal_ops" | "tribal" | "unsorted"  (ranking signal only, never a\n' +
'           gate). polished published->official; WIP/TODO->draft; ops/HR/process/training->internal_ops;\n' +
'           informal notes/Slack dumps and first-person tips ("I crafted...","my trick")->tribal;\n' +
'           cannot tell->unsorted.\n' +
'\n' +
'topic    : {"area": one of "installation_setup","templates_merge_fields","e_signature","integrations",\n' +
'           "permissions_security","billing_licensing","errors_troubleshooting","api_developer","other";\n' +
'           "detail": free text <= 6 words}\n' +
'\n' +
'audience : "customer" | "agent" | "internal"  - this is the most common mislabel, read carefully:\n' +
'  customer = written to be read by an end user of the product.\n' +
'  agent    = product/support KNOWLEDGE an agent uses to solve a customer PRODUCT issue (how a feature\n' +
'             works, how to fix a product error). Customer-facing in substance, just agent-voiced.\n' +
'  internal = how the TEAM/COMPANY operates: triage, routing, which queue, rules of engagement,\n' +
'             escalation, onboarding, tooling, HR, process. If the page tells an agent how to\n' +
'             ROUTE/COORDINATE rather than how to SOLVE a product problem, it is internal - even though\n' +
'             agents read it. When torn between agent and internal, choose internal.\n' +
'\n' +
'red_flags: array of short phrases (empty [] if none). Scan the FULL body, including negations and\n' +
'  caveats. List every internal/leak signal you find:\n' +
'  - caveat phrases, DISPOSITIVE on their own: "do not send","do not share","internal only","for support\n' +
'    use","not for customers","confidential".\n' +
'  - team operations: triage / case routing / which queue / rules of engagement / escalation paths /\n' +
'    when-or-how to submit a case to a team / SLA / staffing.\n' +
'  - internal Support techniques against a customer org: bypassing, overriding, or accessing restricted\n' +
'    permissions/views in a client org.\n' +
'  - HR/PTO/benefits; meeting/standup notes; onboarding/training; internal tooling/Slackbot/bots;\n' +
'    change-request/runbooks; roadmap/unreleased; internal pricing/discount logic; credentials/keys/\n' +
'    secrets; named customers/accounts/contracts.\n' +
'\n' +
'visibility : a PROPOSAL only (emit under key "value"); a code gate decides the committed label. Propose\n' +
'  "customer_safe" ONLY if you believe ALL hold: audience=="customer", product!="None",\n' +
'  format!="internal_process", red_flags empty. Otherwise "agent_only". Use "escalate_only" when the page\n' +
'  itself says the case must be escalated / handed off rather than answered.\n' +
'  visibility.confidence = your calibrated certainty in the proposal, and it MUST NOT EXCEED your audience\n' +
'  certainty: if you are unsure who the page is for, that uncertainty caps this number. A proposal below\n' +
'  0.80 is demoted by the gate, so only propose customer_safe when you are genuinely confident.\n' +
'\n' +
'keywords : array of EXACTLY 8-10 lowercase search terms/short phrases (1-4 words each) someone would TYPE\n' +
'  to find THIS page. These power keyword retrieval, so make them count: include the specific feature,\n' +
'  object, button, and setting names; the user action or task; any error/symptom wording; and common\n' +
'  SYNONYMS and abbreviations a customer OR an agent might use for the same thing. Prefer specific over\n' +
'  generic (e.g. "merge field syntax", "void signature request", "envelope recipient", "pdf upload\n' +
'  template" - NOT "salesforce", "document", "feature"). Distinct entries, no duplicates, and do not just\n' +
'  echo the title back. Always return 8-10 even for short pages.\n' +
'\n' +
'OUTPUT: a single JSON object and nothing else, shape:\n' +
'{"product":{"value":"","confidence":0.0,"rationale":""},\n' +
' "format":{"value":"","confidence":0.0,"rationale":""},\n' +
' "trust":{"value":"","confidence":0.0,"rationale":""},\n' +
' "topic":{"area":"","detail":"","confidence":0.0,"rationale":""},\n' +
' "audience":{"value":"","confidence":0.0,"rationale":""},\n' +
' "red_flags":[],\n' +
' "keywords":[],\n' +
' "visibility":{"value":"","confidence":0.0,"rationale":""}}\n' +
'\n' +
'Examples (API vocab; red_flags shown). The four NEGs are real past misses - learn the pattern:\n' +
'NEG Triaging new cases ("decide whether the case belongs in the Support or Sales queue"): product None,\n' +
'  format internal_process, trust internal_ops, audience internal,\n' +
'  red_flags ["case triage / queue routing"], visibility agent_only (routing, not a product problem).\n' +
'NEG Support rules of engagement ("a streamlined process for engaging the Support team"): product None,\n' +
'  format internal_process, trust internal_ops, audience internal,\n' +
'  red_flags ["rules of engagement / cross-team process"], visibility agent_only.\n' +
'NEG Check your org document count ("do not send any of the following to customers..."): product S-Docs,\n' +
'  format reference, trust internal_ops, audience agent,\n' +
'  red_flags ["\'do not send\' caveat in body"], visibility agent_only (the caveat is dispositive).\n' +
'NEG Cannot view document due to permissions ("use the Support override to view in the client org"):\n' +
'  product S-Docs, format troubleshooting, trust internal_ops, audience agent,\n' +
'  red_flags ["Support override of viewing restrictions in a client org"], visibility agent_only.\n' +
'POS Published S-Docs merge-field how-to: product S-Docs, format how_to, trust official,\n' +
'  audience customer, red_flags [], visibility customer_safe (product help, zero red flags).\n' +
'POS S-Sign "recipient did not get the email" fix: product S-Sign, format troubleshooting,\n' +
'  trust official, audience customer, red_flags [], visibility customer_safe.';

    // ---- json helpers ----

    private static String axisValue(Map<String, Object> root, String axis) {
        Map<String, Object> m = asMap(root.get(axis));
        return m == null ? null : str(m.get('value'));
    }

    private static Decimal confidenceOf(Object axisObj) {
        Map<String, Object> m = asMap(axisObj);
        if (m == null || m.get('confidence') == null) { return null; }
        try { return Decimal.valueOf(String.valueOf(m.get('confidence'))); }
        catch (Exception e) { return null; }
    }

    private static Map<String, Object> asMap(Object o) {
        return (o instanceof Map<String, Object>) ? (Map<String, Object>) o : null;
    }

    private static String str(Object o) { return o == null ? null : String.valueOf(o); }

    private static List<String> normKeywords(List<String> raw) {
        List<String> out = new List<String>();
        if (raw == null) { return out; }
        Set<String> seen = new Set<String>();
        for (String k : raw) {
            if (String.isBlank(k)) { continue; }
            String t = k.toLowerCase().trim();
            if (t.length() < 2 || seen.contains(t)) { continue; }
            seen.add(t);
            out.add(t);
            if (out.size() >= 10) { break; }
        }
        return out;
    }

    /** A JSON array of strings -> List<String>, trimming and dropping blanks; anything else -> empty list. */
    private static List<String> strList(Object o) {
        List<String> out = new List<String>();
        if (o instanceof List<Object>) {
            for (Object item : (List<Object>) o) {
                String s = str(item);
                if (!String.isBlank(s)) { out.add(s.trim()); }
            }
        }
        return out;
    }

    private static String slug(String s) {
        if (String.isBlank(s)) { return null; }
        String out = s.toLowerCase().trim().replaceAll('[^a-z0-9]+', '_');
        return out.replaceFirst('^_+', '').replaceFirst('_+$', '');
    }

    private static String normProduct(String value) {
        String s = slug(value);
        if (s == 's_docs') { return 'S-Docs'; }
        if (s == 's_sign') { return 'S-Sign'; }
        if (s == 'both') { return 'Both'; }
        return 'None';
    }

    private static String inSet(String value, Set<String> allowed, String fallback) {
        return (value != null && allowed.contains(value)) ? value : fallback;
    }

    private static String trunc(String s, Integer max) {
        if (s == null) { return null; }
        return s.length() > max ? s.substring(0, max) : s;
    }

    // ---- sync service: enumerate -> (sample) -> fetch -> classify -> (preview | upsert) ----
    // dryRun (default) previews a sample and writes nothing; the full corpus commits via the queueable.

    // 40 pages/link * 2 callouts + 4 sitemaps = 84 callouts, under the 100/transaction ceiling.
    private static final Integer SLICE_SIZE = 40;
    private static final Integer DEFAULT_SAMPLE = 25; // synchronous dry-run cap (callout budget)
    private static final Integer FLUSH_AT = 50;       // upsert in chunks (commit mode) to bound heap

    public class SyncOptions {
        public List<String> sections;     // null/empty -> DEFAULT_SECTIONS
        public String defaultProduct = 'S-Docs';
        public Boolean dryRun = true;     // safe default: preview only
        public Integer sampleSize;        // dry-run page cap (null = DEFAULT_SAMPLE; <=0 = no cap)
        public Boolean classify = true;   // run the AI classification layer (1 ModelsAPI callout/page)
    }

    public virtual class CountedResult {
        public Integer processed = 0;
        public Integer failed = 0;
        public List<String> errors = new List<String>();
    }

    /** One async chain link's outcome; nextOffset < 0 means the corpus is fully processed. */
    public class SliceResult extends CountedResult {
        public Integer nextOffset = -1;
        public Integer recordsBuilt = 0;
    }

    public class Preview {
        public String key;
        public String title;
        public String section;
        public String product;
        public String visibility;
        public String sourceType;
        public String solutionType;
        public String audience;
        public String contentFormat;
        public String topicArea;
        public Decimal visibilityConfidence;
        public String bodyPreview;
    }

    public class SyncResult extends CountedResult {
        public Boolean dryRun;
        public Integer pagesFetched = 0;
        public Integer recordsBuilt = 0;
        public List<Preview> previews = new List<Preview>();
    }

    public static SyncResult run(SyncOptions opts) {
        opts = normalize(opts);
        SyncResult out = new SyncResult();
        out.dryRun = opts.dryRun;

        List<UrlRef> refs = listUrls(opts.sections);
        Integer cap = (opts.sampleSize == null) ? DEFAULT_SAMPLE : opts.sampleSize;
        Integer lim = (cap > 0) ? Math.min(cap, refs.size()) : refs.size();

        List<SupportSolutionStore.PageInput> buffer = new List<SupportSolutionStore.PageInput>();

        for (Integer i = 0; i < lim; i++) {
            processRef(refs[i], opts, out, buffer);
        }
        if (!opts.dryRun && !buffer.isEmpty()) { flush(buffer, out); }
        return out;
    }

    private static void processRef(UrlRef ref, SyncOptions opts, SyncResult out,
            List<SupportSolutionStore.PageInput> buffer) {
        try {
            DocPage dp = fetchPage(ref);
            out.pagesFetched++;
            SupportSolutionStore.PageInput pi = toPageInput(dp, opts);
            out.recordsBuilt++;
            if (opts.dryRun) {
                out.previews.add(toPreview(pi, dp.section));
            } else {
                buffer.add(pi);
                if (buffer.size() >= FLUSH_AT) {
                    flush(buffer, out);
                    buffer.clear();
                }
            }
        } catch (Exception e) {
            out.failed++;
            out.errors.add((ref == null ? '(null)' : ref.url) + ' -> ' + e.getMessage());
        }
    }

    private static void flush(List<SupportSolutionStore.PageInput> buffer, CountedResult out) {
        SupportSolutionStore.IngestionResult ir = SupportSolutionStore.upsertPages(buffer);
        out.processed += ir.processed;
        out.failed += ir.failed;
        out.errors.addAll(ir.errors);
    }

    // ---- async chain (commit the full corpus across transactions) ----

    /**
     * Process one offset window of the enumerated refs and COMMIT it. Returns the next offset
     * (nextOffset < 0 = done). The caller (HelpSdocsSyncQueueable) enumerates ONCE and carries the ref
     * list down the chain, so each link only fetches + classifies its window - no re-enumeration.
     */
    public static SliceResult runSlice(SyncOptions opts, List<UrlRef> refs, Integer offset) {
        opts = normalize(opts);
        SliceResult sr = new SliceResult();
        if (refs == null || refs.isEmpty()) { return sr; }
        Integer start = (offset == null || offset < 0) ? 0 : offset;
        Integer endIdx = Math.min(start + SLICE_SIZE, refs.size());

        List<SupportSolutionStore.PageInput> buffer = new List<SupportSolutionStore.PageInput>();
        for (Integer i = start; i < endIdx; i++) {
            try {
                DocPage dp = fetchPage(refs[i]);
                buffer.add(toPageInput(dp, opts));
                sr.recordsBuilt++;
                if (buffer.size() >= FLUSH_AT) {
                    flush(buffer, sr);
                    buffer.clear();
                }
            } catch (Exception e) {
                sr.failed++;
                sr.errors.add(refs[i].url + ' -> ' + e.getMessage());
            }
        }
        if (!buffer.isEmpty()) { flush(buffer, sr); }
        sr.nextOffset = (endIdx < refs.size()) ? endIdx : -1;
        return sr;
    }

    /**
     * Final chain step: deactivate active records in the synced sections that weren't touched this run
     * ("touched" = Last_Synced__c >= runStart). Handles pages removed from the docs site. Sections are
     * stored on Source_Space_Key__c (the generic source-provenance field).
     */
    public static Integer reconcileByTimestamp(SyncOptions opts, Datetime runStart) {
        opts = normalize(opts);
        if (runStart == null) { return 0; }
        Set<String> sectionSet = new Set<String>(opts.sections);
        Set<String> stale = new Set<String>();
        for (Support_Solution__c s : [
                SELECT Confluence_Page_Id__c FROM Support_Solution__c
                WHERE Active__c = true AND Source_Space_Key__c IN :sectionSet
                  AND (Last_Synced__c < :runStart OR Last_Synced__c = null)]) {
            stale.add(s.Confluence_Page_Id__c);
        }
        if (stale.isEmpty()) { return 0; }
        return SupportSolutionStore.deactivatePages(stale).processed;
    }

    // ---- build ----

    /** One fetched page -> one PageInput. Visibility is FORCED customer_safe (see the class banner). */
    @TestVisible
    private static SupportSolutionStore.PageInput toPageInput(DocPage dp, SyncOptions opts) {
        PageContent cp = new PageContent();
        cp.title = dp.title;
        cp.sectionKey = dp.section;
        cp.body = dp.markdown;
        cp.lastModified = dp.lastModified;

        Classification cls = classify(cp, sectionBaseProduct(dp.section, opts.defaultProduct), opts.classify);

        SupportSolutionStore.PageInput pi = new SupportSolutionStore.PageInput();
        pi.pageId = dp.id;
        pi.title = dp.title;
        pi.htmlBody = dp.markdown; // stripHtml is a near-passthrough on clean markdown
        pi.url = dp.url;
        pi.product = productForSection(dp.section, cls.product, opts.defaultProduct);
        // Public published docs: safe to use in customer replies by definition. The gate does not apply.
        pi.visibility = SupportDraftVocab.VIS_CUSTOMER_SAFE;
        pi.sourceType = firstNonBlank(cls.sourceType, 'official'); // the corpus is official published docs
        pi.solutionType = solutionTypeFor(cls.contentFormat); // blank -> explainer default
        pi.contentFormat = cls.contentFormat;
        pi.audience = cls.audience;
        pi.topicArea = cls.topicArea;
        pi.visibilityConfidence = cls.visibilityConfidence;
        pi.keywords = buildKeywords(cls, dp.title); // 8-10 model keywords -> Keywords__c (retrieval signal)
        pi.sourceSpaceKey = dp.section;
        pi.isActive = true;
        return pi;
    }

    /** Section -> Product__c. Product-specific sections are authoritative; cross-cutting sections defer
     *  to the classifier's product call, then to the default. */
    @TestVisible
    private static String productForSection(String section, String classifierProduct, String dflt) {
        if (section == 's-sign') { return 'S-Sign'; }
        if (section == 'sdocs') { return 'S-Docs'; }
        if (classifierProduct == 'S-Docs' || classifierProduct == 'S-Sign') { return classifierProduct; }
        return String.isBlank(dflt) ? 'S-Docs' : dflt;
    }

    /** Best single-product hint for the classifier's heuristic fallback (no 'Both'/'None' guessing). */
    private static String sectionBaseProduct(String section, String dflt) {
        if (section == 's-sign') { return 'S-Sign'; }
        if (section == 'sdocs') { return 'S-Docs'; }
        return String.isBlank(dflt) ? 'S-Docs' : dflt;
    }

    private static SyncOptions normalize(SyncOptions opts) {
        if (opts == null) { opts = new SyncOptions(); }
        if (opts.sections == null || opts.sections.isEmpty()) {
            opts.sections = DEFAULT_SECTIONS;
        }
        if (String.isBlank(opts.defaultProduct)) { opts.defaultProduct = 'S-Docs'; }
        return opts;
    }

    private static Preview toPreview(SupportSolutionStore.PageInput pi, String section) {
        Preview pv = new Preview();
        pv.key = pi.pageId;
        pv.title = pi.title;
        pv.section = section;
        pv.product = pi.product;
        pv.visibility = pi.visibility;
        pv.sourceType = pi.sourceType;
        pv.solutionType = String.isBlank(pi.solutionType) ? 'explainer (default)' : pi.solutionType;
        pv.audience = String.isBlank(pi.audience) ? 'internal (default)' : pi.audience;
        pv.contentFormat = pi.contentFormat;
        pv.topicArea = String.isBlank(pi.topicArea) ? 'other (default)' : pi.topicArea;
        pv.visibilityConfidence = pi.visibilityConfidence;
        String clean = SupportSolutionStore.stripHtml(
            (pi.htmlBody != null && pi.htmlBody.length() > 1500) ? pi.htmlBody.substring(0, 1500) : pi.htmlBody);
        pv.bodyPreview = (clean.length() > 200) ? clean.substring(0, 200) + '...' : clean;
        return pv;
    }

    @TestVisible
    private static String buildKeywords(Classification cls, String title) {
        List<String> kw = new List<String>();
        Set<String> seen = new Set<String>();
        if (cls != null && cls.keywords != null) {
            for (String k : cls.keywords) { addKeyword(kw, seen, k); }
        }
        if (kw.size() < 8) { // supplement to reach a useful count
            if (cls != null) {
                addKeyword(kw, seen, cls.topicDetail);
                if (String.isNotBlank(cls.topicArea)) { addKeyword(kw, seen, cls.topicArea.replace('_', ' ')); }
            }
            if (String.isNotBlank(title)) {
                for (String t : title.toLowerCase().split('[^a-z0-9]+')) {
                    if (kw.size() >= 10) { break; }
                    if (t != null && t.length() >= 3) { addKeyword(kw, seen, t); }
                }
            }
        }
        List<String> capped = new List<String>();
        for (Integer i = 0; i < kw.size() && i < 10; i++) { capped.add(kw[i]); }
        return String.join(capped, ', ');
    }

    private static void addKeyword(List<String> kw, Set<String> seen, String raw) {
        if (String.isBlank(raw)) { return; }
        String t = raw.toLowerCase().trim();
        if (t.length() < 2 || seen.contains(t)) { return; }
        seen.add(t);
        kw.add(t);
    }

    // ---- sync queueable: enumerate once, commit one offset window per link, reconcile at the end ----
    public class HelpSdocsSyncQueueable implements Queueable, Database.AllowsCallouts {

        private SyncOptions opts;
        private List<UrlRef> refs; // enumerated once on the first link, carried down the chain
        private Integer offset;
        private Datetime runStart;

        public HelpSdocsSyncQueueable(SyncOptions opts) {
            this(opts, null, null, null);
        }

        public HelpSdocsSyncQueueable(SyncOptions opts, List<UrlRef> refs, Integer offset, Datetime runStart) {
            this.opts = opts;
            this.refs = refs;
            this.offset = offset;
            this.runStart = runStart;
        }

        public void execute(QueueableContext ctx) {
            if (opts == null) { opts = new SyncOptions(); }
            opts.dryRun = false;                                  // the queue exists to commit
            if (runStart == null) { runStart = Datetime.now(); }  // stamped once, carried down the chain
            if (refs == null) { refs = listUrls(opts.sections); } // enumerate once

            SliceResult sr = runSlice(opts, refs, offset);

            // More pages -> next link. Done (or in a test, where chaining isn't allowed) -> reconcile.
            if (sr.nextOffset >= 0 && !Test.isRunningTest()) {
                System.enqueueJob(new HelpSdocsSyncQueueable(opts, refs, sr.nextOffset, runStart));
            } else {
                reconcileByTimestamp(opts, runStart);
            }
        }
    }
}
