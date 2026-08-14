/**
 * Common-case seeding from the S-Docs case sheet (CSV): Issue -> Name+Keywords, JUNE answer ->
 * Body__c, Case # -> 'sdocs-case-<n>' external id, Common_Case__c = true. DQ rules: ambiguous glued
 * Issue text is flagged needsReview; no-answer rows seed as agent_only with an empty body
 * (retrievable, never customer-reply fuel). Writes through SupportSolutionStore.upsertPages.
 */
public with sharing class CaseSeedImporter {

    @TestVisible private static final String EXT_ID_PREFIX = 'sdocs-case-';
    private static final String SRC_ANSWER = 'official';
    private static final String SRC_NO_ANSWER = 'unsorted';

    public class CaseRow {
        public String caseNumber;     // sheet "Case #"
        public String issue;          // "Issue / Question"
        public String internalAnswer; // "Answer / Response Provided" (internal shorthand; metadata only)
        public String gitbookJune;    // "Answer / Response Provided by Gitbook (JUNE)" -> Body__c (the answer)

        public CaseRow() {}
        public CaseRow(String caseNumber, String issue, String internalAnswer, String gitbookJune) {
            this.caseNumber = caseNumber;
            this.issue = issue;
            this.internalAnswer = internalAnswer;
            this.gitbookJune = gitbookJune;
        }
    }

    public class SeedResult {
        public Integer processed = 0;
        public Integer failed = 0;
        public Integer noAnswer = 0;        // DQ-4 rows seeded agent_only
        public List<String> needsReview = new List<String>(); // DQ-2 ambiguous case numbers to re-export
        public List<String> errors = new List<String>();
    }

    public static SeedResult ingest(List<CaseRow> rows) {
        SeedResult out = new SeedResult();
        if (rows == null || rows.isEmpty()) { return out; }

        List<SupportSolutionStore.PageInput> pages = new List<SupportSolutionStore.PageInput>();
        for (CaseRow r : rows) {
            if (r == null || String.isBlank(r.caseNumber)) {
                out.failed++;
                out.errors.add('Skipped row with blank Case # (issue=' +
                    (r == null ? 'null' : abbrev(r.issue, 40)) + ')');
                continue;
            }
            BuildOutcome bo = toPageInput(r);
            pages.add(bo.page);
            if (bo.noAnswer) { out.noAnswer++; }
            if (bo.needsReview) { out.needsReview.add(r.caseNumber); }
        }

        SupportSolutionStore.IngestionResult ir = SupportSolutionStore.upsertPages(pages);
        out.processed += ir.processed;
        out.failed += ir.failed;
        out.errors.addAll(ir.errors);
        return out;
    }

    /**
     * Ingest the case sheet as CSV (columns: Case #, Issue, internal Answer, Answer (JUNE); header
     * skipped; only the JUNE answer becomes the body). RFC4180-parsed for multiline/quoted cells.
     */
    public static SeedResult ingestCsv(String csv) {
        List<List<String>> rows = parseCsv(csv);
        List<CaseRow> cases = new List<CaseRow>();
        for (Integer i = 1; i < rows.size(); i++) {        // skip header
            List<String> r = rows[i];
            if (r == null || r.isEmpty()) { continue; }
            if (r.size() == 1 && String.isBlank(r[0])) { continue; } // blank line
            cases.add(new CaseRow(col(r, 0), col(r, 1), col(r, 2), col(r, 3))); // col 3 = JUNE answer
        }
        return ingest(cases);
    }

    private static String col(List<String> r, Integer i) {
        return (i < r.size()) ? r[i] : null;
    }

    /** Minimal RFC4180 CSV parser; chunk-based substrings keep large exports under the CPU limit. */
    @TestVisible
    private static List<List<String>> parseCsv(String csv) {
        List<List<String>> rows = new List<List<String>>();
        if (String.isBlank(csv)) { return rows; }
        Integer n = csv.length();
        Integer i = 0;
        List<String> row = new List<String>();
        while (i < n) {
            String field;
            if (csv.substring(i, i + 1) == '"') {
                List<String> parts = new List<String>();
                i++;                                  // skip opening quote
                Integer start = i;
                while (i < n) {
                    String ch = csv.substring(i, i + 1);
                    if (ch == '"') {
                        if (i + 1 < n && csv.substring(i + 1, i + 2) == '"') {
                            parts.add(csv.substring(start, i)); parts.add('"'); // escaped quote
                            i += 2; start = i;
                        } else {
                            parts.add(csv.substring(start, i));
                            i++;                       // skip closing quote
                            break;
                        }
                    } else {
                        i++;
                    }
                }
                field = String.join(parts, '');
            } else {
                Integer start = i;
                while (i < n) {
                    String ch = csv.substring(i, i + 1);
                    if (ch == ',' || ch == '\n' || ch == '\r') { break; }
                    i++;
                }
                field = csv.substring(start, i);
            }
            row.add(field);
            if (i < n) {
                String ch = csv.substring(i, i + 1);
                if (ch == ',') {
                    i++;
                } else if (ch == '\r') {
                    i++;
                    if (i < n && csv.substring(i, i + 1) == '\n') { i++; } // \r\n
                    rows.add(row); row = new List<String>();
                } else if (ch == '\n') {
                    i++;
                    rows.add(row); row = new List<String>();
                }
            }
        }
        if (!row.isEmpty()) { rows.add(row); }
        return rows;
    }

    @TestVisible
    private class BuildOutcome {
        SupportSolutionStore.PageInput page;
        Boolean noAnswer;
        Boolean needsReview;
    }

    @TestVisible
    private static BuildOutcome toPageInput(CaseRow r) {
        BuildOutcome bo = new BuildOutcome();

        String rawIssue = (r.issue == null) ? '' : r.issue;
        NormResult nr = normalizeIssue(rawIssue);

        String juneClean = clean(r.gitbookJune);
        Boolean juneOk = isAnswer(juneClean);

        // The JUNE Gitbook answer is the canonical body. (The April column was retired once June covered
        // every case, so there is no precedence/conflict handling left.)
        String canonical = juneOk ? juneClean : null;
        Boolean noAnswer = (canonical == null);

        SupportSolutionStore.PageInput pi = new SupportSolutionStore.PageInput();
        pi.pageId = EXT_ID_PREFIX + r.caseNumber.trim();
        pi.title = nr.cleaned;                                  // -> Name (truncated to 80 by upsert)
        pi.htmlBody = noAnswer ? '' : canonical;                // -> Body__c (answer payload; empty if none)
        pi.url = null;                                          // the sheet carries no source URL
        pi.product = deriveProduct(rawIssue + ' ' + canonical);
        pi.keywords = buildKeywords(nr.cleaned, canonical);
        pi.isActive = true;
        pi.commonCase = true;

        // DQ-4: a no-answer row stays retrievable on its Issue text but is NEVER customer-reply fuel.
        pi.visibility = noAnswer ? SupportDraftVocab.VIS_AGENT_ONLY : SupportDraftVocab.VIS_CUSTOMER_SAFE;
        pi.sourceType = noAnswer ? SRC_NO_ANSWER : SRC_ANSWER;
        pi.solutionType = 'procedure';                          // case resolutions are step fixes
        pi.sourceSpaceKey = 'sdocs-cases';                     // provenance: the case sheet
        bo.page = pi;
        bo.noAnswer = noAnswer;
        bo.needsReview = nr.needsReview;
        return bo;
    }

    // ---- DQ-2 normalization ------------------------------------------------------------------------------

    @TestVisible
    private class NormResult { String cleaned; Boolean needsReview; }

    /**
     * Re-space glued code tokens with deterministic-only fixes ('__cAPI' -> '__c API', ')that', '>Apex',
     * '101error'). Anything still glued sets needsReview — a wrong guess is worse than leaving it.
     */
    @TestVisible
    private static NormResult normalizeIssue(String raw) {
        NormResult nr = new NormResult();
        String s = (raw == null) ? '' : raw.trim();
        s = s.replaceAll('\\s+', ' ');
        s = s.replaceAll('(__c)([A-Za-z])', '$1 $2');
        s = s.replaceAll('(\\))([A-Za-z])', '$1 $2');
        s = s.replaceAll('(>)([A-Za-z])', '$1 $2');
        s = s.replaceAll('([0-9])([a-z]{4,})', '$1 $2');
        s = s.replaceAll('\\s+', ' ').trim();
        nr.cleaned = s;
        // Ambiguity: any remaining separator-free token of 26+ chars is almost certainly two glued words we
        // can't split safely (e.g. 'align=leftspecified' style runs). Flag, don't guess.
        nr.needsReview = false;
        for (String tok : s.split(' ')) {
            if (tok.length() >= 26 && !tok.contains('http')) { nr.needsReview = true; break; }
        }
        return nr;
    }

    // ---- field derivations -------------------------------------------------------------------------------

    @TestVisible
    private static String deriveProduct(String text) {
        String t = (text == null) ? '' : text.toLowerCase();
        if (t.contains('s-sign') || t.contains('ssign') || t.contains('s_sign')
                || t.contains('signature') || t.contains('signer') || t.contains('counter signer')
                || t.contains('envelope') || t.contains('sign link')) {
            return 'S-Sign';
        }
        return 'S-Docs';
    }

    /** Salient keywords (<=10, question-weighted) — recovers what the 80-char Name truncation drops. */
    @TestVisible
    private static String buildKeywords(String cleanedIssue, String answer) {
        List<String> kw = new List<String>();
        Set<String> seen = new Set<String>();
        addTokens(kw, seen, cleanedIssue, 8);          // question first
        addTokens(kw, seen, answer, 10);               // top up from the answer
        return String.join(kw, ', ');
    }

    private static void addTokens(List<String> kw, Set<String> seen, String text, Integer cap) {
        if (String.isBlank(text)) { return; }
        for (String raw : text.toLowerCase().split('[^a-z0-9_]+')) {
            if (kw.size() >= cap) { break; }
            String tk = raw.trim();
            if (tk.length() < 3 || KW_STOP.contains(tk)) { continue; }
            if (seen.contains(tk)) { continue; }
            seen.add(tk);
            kw.add(tk);
        }
    }

    private static final Set<String> KW_STOP = new Set<String>{
        'the','and','for','with','this','that','was','are','not','you','your','our','have','has','can',
        'cannot','help','issue','problem','please','how','what','when','where','why','from','they','them',
        'will','would','could','should','any','all','get','getting','out','use','using','set','setting',
        'fix','resolve','error','doc','docs','sdocs'
    };

    // ---- answer helpers ----------------------------------------------------------------------------------

    /** A cell counts as a real answer unless it is blank or a known placeholder (DQ-4). */
    @TestVisible
    private static Boolean isAnswer(String s) {
        if (String.isBlank(s)) { return false; }
        String t = s.trim().toLowerCase();
        if (t.length() < 5) { return false; }                         // '--', '-', 'n/a', 'na'
        if (t == 'no resolution recorded') { return false; }
        if (t.startsWith('no resolution recorded')) { return false; } // '... (routed to sales)'
        if (t.contains('routed to sales') && t.length() < 40) { return false; }
        return true;
    }

    private static String clean(String s) {
        return (s == null) ? null : s.trim();
    }

    private static String abbrev(String s, Integer max) {
        if (s == null) { return null; }
        return s.length() > max ? s.substring(0, max) + '...' : s;
    }
}
