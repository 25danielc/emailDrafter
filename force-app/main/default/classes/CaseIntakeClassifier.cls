/**
 * Deterministic (regex/keyword, zero-callout) intake triage for the Origin=Email drafting path.
 * Classifies an inbound case as JUNK (auto-reply loops, bounce notices, no-reply senders,
 * newsletters, calendar invites — not a case at all), BILLING (billing/licensing transactions no
 * KB doc can answer; both confirmed drafted false positives in the 2026-07-16 eval diagnosis were
 * billing threads), or LEGIT (a draftable product question).
 *
 * Shared by the AutomatedEmailDrafting flow, DraftEvalBatchJob, and CaseMiningJob so production,
 * evaluation, and corpus mining all measure the same "legitimate case" denominator. Precision
 * first: a legit case wrongly excluded never gets a draft, so every rule errs toward LEGIT.
 */
public with sharing class CaseIntakeClassifier {

    public static final String CATEGORY_JUNK = 'JUNK';
    public static final String CATEGORY_BILLING = 'BILLING';
    public static final String CATEGORY_LEGIT = 'LEGIT';

    // How much of the (long, often quoted-history-laden) description the billing rules may see.
    // Billing intent shows up in the ask, not in page-3 signatures/footers.
    @TestVisible private static final Integer BILLING_BODY_SCAN_CHARS = 500;
    // An invite-only body is boilerplate-sized; a real question wrapped around an invite is longer.
    @TestVisible private static final Integer INVITE_BODY_MAX_CHARS = 800;

    // ---- JUNK signals (any one suffices) ----
    @TestVisible private static final Pattern SENDER_JUNK = Pattern.compile(
        '(?i)(no.?reply|do.?not.?reply|mailer-daemon|postmaster@|bounce[s@.-]|notifications?@|news(letter)?s?@|marketing@)');
    @TestVisible private static final Pattern SUBJECT_AUTO_REPLY = Pattern.compile(
        '(?i)^\\s*((re:|fw(d)?:)\\s*)*(automatic reply|auto.?reply|auto.?response|out of (the )?office)');
    @TestVisible private static final Pattern SUBJECT_BOUNCE = Pattern.compile(
        '(?i)(undeliverable|undelivered mail|delivery status notification|delivery has failed'
        + '|mail delivery (failed|subsystem)|returned mail|read receipt|message blocked)');
    // Support's own "Ticket received:" acknowledgment bouncing back in as a new case (the mail
    // loop the diagnosis found; arrives with helpdesk "[#REF]" prefixes, so unanchored — the colon
    // keeps prose like "no ticket received after signing" out).
    @TestVisible private static final Pattern SUBJECT_ACK_LOOP = Pattern.compile(
        '(?i)(ticket received:|s-docs support case #:)');
    @TestVisible private static final Pattern SUBJECT_INVITE = Pattern.compile(
        '(?i)(^|\\s)(invitation|accepted|declined|tentative|canceled|cancelled|updated invitation)\\s*:');
    // Outlook message-recall notices bounce into Email-to-Case as new cases (2 seen per 100).
    @TestVisible private static final Pattern SUBJECT_RECALL = Pattern.compile(
        '(?i)^\\s*recall:');
    @TestVisible private static final Pattern SUBJECT_NEWSLETTER = Pattern.compile(
        '(?i)(newsletter|webinar|\\d{1,2}% off|black friday|product update(s)? digest)');
    // Invite-only bodies: meeting boilerplate with no question around it.
    @TestVisible private static final Pattern BODY_INVITE = Pattern.compile(
        '(?i)(microsoft teams meeting|join zoom meeting|meeting id:|join on your computer)');

    // ---- BILLING signals (transactional intent, not product troubleshooting) ----
    // "invalid license key error" is a LEGIT known-error topic; only issuance/commerce intent
    // routes to billing, so the verbs stay transactional and 'error|invalid|fail' vetoes.
    @TestVisible private static final Pattern BILLING_TERMS = Pattern.compile(
        '(?i)(invoice|billing|renewal|purchase order|quotation|quote for|pricing|price list'
        + '|refund|payment|receipt|w-9|remittance)');
    @TestVisible private static final Pattern LICENSE_ISSUANCE = Pattern.compile(
        '(?i)((issue|send|provide|extend|purchase|buy|renew)\\w*\\s+(us\\s+|me\\s+|a\\s+|an\\s+|the\\s+|our\\s+|new\\s+|temporary\\s+|temp\\s+)*(licen[cs]e|trial|subscription)'
        + '|(licen[cs]e|trial|subscription)\\s+(key\\s+)?(purchase|renewal|extension|quote)'
        // seat-count / entitlement commerce: "add(itional) licences", "license count", "quota reset"
        + '|(add|additional|more|extra|increase)\\w*\\s+(\\w+\\s+){0,2}licen[cs]es?\\b'
        + '|licen[cs]e count|quota (reset|increase))');
    @TestVisible private static final Pattern TROUBLESHOOT_VETO = Pattern.compile(
        '(?i)(error|invalid|fail(ed|ing|ure)?|exception|not work|doesn\'?t work|unable to|issue with|problem with|bug)');
    // A billing/pricing thread often wraps a genuine product how-to question (e.g. a "...Pricing" subject
    // whose body asks how to add a QR code to a template). Route those to LEGIT, not BILLING. Requires BOTH
    // a how-to phrasing AND a product-feature noun so pure commerce asks ("how do I get a renewal quote")
    // are not vetoed. Scanned over a wider window than billing, since the ask can sit deep in a reply.
    @TestVisible private static final Integer HOWTO_BODY_SCAN_CHARS = 2000;
    @TestVisible private static final Pattern PRODUCT_HOWTO = Pattern.compile(
        '(?i)\\bhow (to|do i|can i|would i|should i|does)\\b'
        + '|\\bcould you (remind|tell|show|explain|help)\\b|\\bis there a way to\\b');
    @TestVisible private static final Pattern PRODUCT_NOUN = Pattern.compile(
        '(?i)(template|merge ?field|formula field|button code|qr code|bar ?code|signature|s-sign|s-doc'
        + '|generate|document|pdf|docx|render|component|related list|picklist|watermark|header|footer'
        + '|mass merge|writeback|runtime prompt)');

    /** Plain-Apex result for direct callers (eval + mining jobs). */
    public class Verdict {
        public String category;
        public String reason;
        public Verdict(String category, String reason) {
            this.category = category;
            this.reason = reason;
        }
    }

    public static Verdict classify(String subject, String description, String suppliedEmail) {
        String subj = (subject == null) ? '' : subject.trim();
        String body = (description == null) ? '' : description.trim();
        String sender = (suppliedEmail == null) ? '' : suppliedEmail.trim();

        // --- JUNK ---
        if (String.isNotBlank(sender) && SENDER_JUNK.matcher(sender).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: automated/no-reply sender (' + sender + ').');
        }
        if (SUBJECT_AUTO_REPLY.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: auto-reply/out-of-office subject.');
        }
        if (SUBJECT_BOUNCE.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: delivery/bounce notification subject.');
        }
        if (SUBJECT_ACK_LOOP.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: support acknowledgment loop ("Ticket received").');
        }
        if (SUBJECT_INVITE.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: calendar invite/response subject.');
        }
        if (SUBJECT_RECALL.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: Outlook message-recall notice.');
        }
        if (SUBJECT_NEWSLETTER.matcher(subj).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: newsletter/marketing subject.');
        }
        if (String.isNotBlank(body) && body.length() <= INVITE_BODY_MAX_CHARS
                && BODY_INVITE.matcher(body).find()) {
            return new Verdict(CATEGORY_JUNK, 'Junk mail: meeting-invite-only body.');
        }

        // --- BILLING (scan the subject + the opening of the body, where the ask lives) ---
        String scan = subj + '\n' + (body.length() > BILLING_BODY_SCAN_CHARS
            ? body.substring(0, BILLING_BODY_SCAN_CHARS) : body);
        Boolean troubleshooting = TROUBLESHOOT_VETO.matcher(scan).find();
        // A buried product how-to question makes this a draftable case, not a billing transaction.
        String howtoScan = subj + '\n' + (body.length() > HOWTO_BODY_SCAN_CHARS
            ? body.substring(0, HOWTO_BODY_SCAN_CHARS) : body);
        Boolean productQuestion = PRODUCT_HOWTO.matcher(howtoScan).find()
            && PRODUCT_NOUN.matcher(howtoScan).find();
        if (!troubleshooting && !productQuestion) {
            if (BILLING_TERMS.matcher(scan).find()) {
                return new Verdict(CATEGORY_BILLING,
                    'Billing/licensing: billing/purchasing request, not a product question.');
            }
            if (LICENSE_ISSUANCE.matcher(scan).find()) {
                return new Verdict(CATEGORY_BILLING,
                    'Billing/licensing: license/trial issuance request, not a product question.');
            }
        }

        return new Verdict(CATEGORY_LEGIT, null);
    }

    // ---- Flow entry point ----

    @InvocableMethod(label='Classify Case Intake'
        description='Deterministic triage of an inbound email case: JUNK (auto-replies, bounces, newsletters, invites), BILLING (billing/licensing transactions), or LEGIT (draftable product question). No callouts.')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            if (req == null) {
                res.category = CATEGORY_LEGIT; // fail open: never block drafting on a bad input
            } else {
                Verdict v = classify(req.subject, req.description, req.suppliedEmail);
                res.category = v.category;
                res.reason = v.reason;
            }
            out.add(res);
        }
        return out;
    }

    public class Request {
        @InvocableVariable(label='Case Subject') public String subject;
        @InvocableVariable(label='Case Description') public String description;
        @InvocableVariable(label='Supplied Email (sender)') public String suppliedEmail;
    }

    public class Result {
        @InvocableVariable(label='Category (JUNK | BILLING | LEGIT)') public String category;
        @InvocableVariable(label='Reason (human-readable, stamped into AI Draft Notes)') public String reason;
    }
}
