/**
 * Both halves of the AI draft-reply email loop. PUBLISH (flow-invoked) inserts a Draft-status
 * EmailMessage on the Case for agent review — it never sends. REVIEW & SEND (LWC-invoked,
 * human-triggered only) backs the reviewAiDraft quick action.
 * Org prerequisite: Setup > Support Settings > "Enable Email Drafts" (insert failure is caught and
 * stamped on AI_Draft_Notes__c rather than failing the async drafting transaction).
 */
public with sharing class CaseDraftEmailPublisher {

    @TestVisible private static final String STATUS_DRAFTED = SupportDraftVocab.STATUS_DRAFTED;
    // EmailMessage.Status picklist: '5' = Draft (editable in the Lightning composer).
    @TestVisible private static final String EMAILMESSAGE_STATUS_DRAFT = '5';
    // Used when the case owner is a queue or has no email signature on file.
    @TestVisible private static final String SIGNOFF_FALLBACK = 'Sincerely,\nThe Support Team';

    public interface EmailWriter {
        void write(List<SObject> records); // throws on feature/validation failure
    }
    private class DmlEmailWriter implements EmailWriter {
        public void write(List<SObject> records) {
            if (records == null || records.isEmpty()) { return; }
            insert records;
        }
    }
    @TestVisible static EmailWriter writer = new DmlEmailWriter();

    // Test-only overrides (CMDT and real org users can't be set up in tests).
    @TestVisible static String testFromAddressOverride;
    @TestVisible static String testOwnerSignatureOverride;
    @TestVisible static String testOwnerEmailOverride;

    public class Request {
        @InvocableVariable(required=true label='Case Id') public Id caseId;
        @InvocableVariable(label='AI Draft Status (from orchestrator)') public String draftStatus;
        @InvocableVariable(label='AI Draft Body (from orchestrator)') public String draftBody;
    }

    public class Result {
        @InvocableVariable public Boolean emailCreated;
        @InvocableVariable public String emailMessageId;
        @InvocableVariable public String note;
    }

    @InvocableMethod(label='Create Draft Reply Email'
        description='For a DRAFTED case, inserts a Draft-status EmailMessage (a reviewable, one-click-sendable reply) on the Case. Never sends. Skips ESCALATE / NO_DRAFT_* and empty bodies. Requires "Enable Email Drafts" in Support Settings.')
    public static List<Result> publish(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) { return results; }

        // Only DRAFTED rows with a real body get an email. One Result per Request, in order.
        List<Request> draftable = new List<Request>();
        Map<Id, Result> resultByCase = new Map<Id, Result>();
        for (Request req : requests) {
            Result r = new Result();
            r.emailCreated = false;
            results.add(r);
            if (req != null && req.caseId != null
                    && STATUS_DRAFTED.equals(req.draftStatus)
                    && String.isNotBlank(req.draftBody)) {
                draftable.add(req);
                resultByCase.put(req.caseId, r); // assumes one Request per Case (true for the per-interview Flow)
            } else {
                r.note = 'No email created: status is not DRAFTED or the draft body is empty.';
            }
        }
        if (draftable.isEmpty()) { return results; }

        List<DraftBundle> bundles = buildDrafts(draftable);
        if (bundles.isEmpty()) { return results; }

        List<EmailMessage> emails = new List<EmailMessage>();
        for (DraftBundle b : bundles) { emails.add(b.email); }

        // The Email-Drafts-disabled error surfaces on this insert -> handled gracefully.
        try {
            writer.write(emails);
        } catch (Exception e) {
            handleInsertFailure(bundles, e, resultByCase);
            return results;
        }

        // Relations are best effort: a relation failure must not lose the draft.
        List<EmailMessageRelation> relations = new List<EmailMessageRelation>();
        for (DraftBundle b : bundles) {
            for (EmailMessageRelation rel : b.relations) {
                rel.EmailMessageId = b.email.Id;
                relations.add(rel);
            }
            Result r = resultByCase.get(b.caseId);
            if (r != null) {
                r.emailCreated = true;
                r.emailMessageId = b.email.Id;
                r.note = 'Draft reply email created for agent review.';
            }
        }
        if (!relations.isEmpty()) {
            try {
                writer.write(relations);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'EmailMessageRelation insert failed (draft kept): ' + e.getMessage());
            }
        }
        return results;
    }

    @TestVisible
    private static List<DraftBundle> buildDrafts(List<Request> reqs) {
        List<DraftBundle> out = new List<DraftBundle>();

        Set<Id> caseIds = new Set<Id>();
        for (Request req : reqs) { caseIds.add(req.caseId); }

        // Account.CSM_Email__c / CS_Manager__c: the account's CSM, Cc'd on the draft when present.
        Map<Id, Case> caseById = new Map<Id, Case>(
            [SELECT Id, Subject, ContactId, OwnerId, Account.CSM_Email__c, Account.CS_Manager__c
             FROM Case WHERE Id IN :caseIds]);

        // Case owner: their Email becomes the reply's From and their (rich-HTML) Signature the sign-off.
        Map<Id, User> ownerByCase = buildOwnerUsers(caseById.values());

        // The earliest inbound message is the reply's To address and thread anchor.
        Map<Id, EmailMessage> inboundByCase = new Map<Id, EmailMessage>();
        for (EmailMessage em : [SELECT Id, ParentId, FromAddress
                                FROM EmailMessage
                                WHERE ParentId IN :caseIds AND Incoming = true
                                ORDER BY MessageDate ASC NULLS LAST, CreatedDate ASC]) {
            if (!inboundByCase.containsKey(em.ParentId)) { inboundByCase.put(em.ParentId, em); }
        }

        String cmdtFromAddr = loadFromAddress();
        Id runningUserId = UserInfo.getUserId();

        for (Request req : reqs) {
            Case c = caseById.get(req.caseId);
            EmailMessage inbound = inboundByCase.get(req.caseId);
            // Without the inbound message we can't address or thread a reply -> no email.
            if (c == null || inbound == null || String.isBlank(inbound.FromAddress)) { continue; }

            String toAddr = inbound.FromAddress;

            EmailMessage em = new EmailMessage();
            em.ParentId = req.caseId;
            em.Status = EMAILMESSAGE_STATUS_DRAFT;
            em.IsPrivateDraft = false;                      // visible to any agent with case access
            em.Incoming = false;
            em.Subject = 'Re: ' + (c.Subject == null ? '' : c.Subject);
            // HTML renderers collapse newlines, so the plain-text draft is converted (escape + <br>) for
            // HtmlBody while TextBody keeps the raw text. The owner's rich-HTML signature is appended raw
            // to HtmlBody and tag-stripped for TextBody; no signature -> generic team sign-off.
            User owner = ownerByCase.get(req.caseId);
            String htmlSig = (owner == null) ? null : owner.Signature;
            if (String.isNotBlank(htmlSig)) {
                em.HtmlBody = toHtmlBody(req.draftBody) + '<br><br>' + htmlSig;
                em.TextBody = req.draftBody + '\n\n' + htmlToPlainText(htmlSig);
            } else {
                String signed = req.draftBody + '\n\n' + SIGNOFF_FALLBACK;
                em.HtmlBody = toHtmlBody(signed);
                em.TextBody = signed;
            }
            em.ToAddress = toAddr;
            // From = the case owner so the reply reads person-to-person; queue-owned/email-less owners
            // fall back to the CMDT reply address. ValidatedFromAddress is only set for the CMDT address
            // (an individual owner's address can't be pre-validated here).
            String ownerEmail = (owner == null) ? null : owner.Email;
            String fromAddr = String.isNotBlank(ownerEmail) ? ownerEmail : cmdtFromAddr;
            em.FromAddress = fromAddr;
            if (String.isBlank(ownerEmail) && String.isNotBlank(cmdtFromAddr)) {
                em.ValidatedFromAddress = cmdtFromAddr;
            }
            em.ReplyToEmailMessageId = inbound.Id;

            String csmEmail = (c.Account == null) ? null : c.Account.CSM_Email__c;
            Id csmUserId = (c.Account == null) ? null : c.Account.CS_Manager__c;
            if (String.isNotBlank(csmEmail)) { em.CcAddress = csmEmail; }

            // EmailMessageRelation rows let the Lightning composer resolve addresses to people.
            List<EmailMessageRelation> rels = new List<EmailMessageRelation>();
            if (c.ContactId != null) {
                rels.add(new EmailMessageRelation(
                    RelationId = c.ContactId, RelationType = 'ToAddress', RelationAddress = toAddr));
            }
            if (String.isNotBlank(fromAddr)) {
                Id fromUserId = (String.isNotBlank(ownerEmail) && owner.Id != null) ? owner.Id : runningUserId;
                rels.add(new EmailMessageRelation(
                    RelationId = fromUserId, RelationType = 'FromAddress', RelationAddress = fromAddr));
            }
            if (String.isNotBlank(csmEmail) && csmUserId != null) {
                rels.add(new EmailMessageRelation(
                    RelationId = csmUserId, RelationType = 'CcAddress', RelationAddress = csmEmail));
            }

            DraftBundle b = new DraftBundle();
            b.caseId = req.caseId;
            b.email = em;
            b.relations = rels;
            out.add(b);
        }
        return out;
    }

    // Insert failure (usually Email Drafts disabled): log + stamp AI_Draft_Notes__c, never throw.
    private static void handleInsertFailure(List<DraftBundle> bundles, Exception e, Map<Id, Result> resultByCase) {
        String msg = '[AI draft email NOT created: ' + e.getMessage()
            + ' -- verify "Enable Email Drafts" is on in Setup > Support Settings.]';
        System.debug(LoggingLevel.ERROR, msg);

        Set<Id> caseIds = new Set<Id>();
        for (DraftBundle b : bundles) {
            caseIds.add(b.caseId);
            Result r = resultByCase.get(b.caseId);
            if (r != null) { r.emailCreated = false; r.note = msg; }
        }

        List<Case> toUpdate = new List<Case>();
        for (Case c : [SELECT Id, AI_Draft_Notes__c FROM Case WHERE Id IN :caseIds]) {
            c.AI_Draft_Notes__c = (String.isBlank(c.AI_Draft_Notes__c) ? '' : c.AI_Draft_Notes__c + '\n') + msg;
            toUpdate.add(c);
        }
        try {
            update toUpdate;
        } catch (Exception e2) {
            System.debug(LoggingLevel.ERROR, 'Failed to stamp Email-Drafts-disabled note on Case: ' + e2.getMessage());
        }
    }

    @TestVisible
    private static String toHtmlBody(String plain) {
        if (String.isBlank(plain)) { return plain; }
        String normalized = plain.replace('\r\n', '\n').replace('\r', '\n');
        return normalized.escapeHtml4().replace('\n', '<br>\n');
    }

    /**
     * Case owners as Users (Email + Signature), keyed by Case Id. Owner is polymorphic: only 005-prefix
     * owners are queried, a Queue owner just gets the fallbacks. Lookup failures return an empty map —
     * they must never break draft creation.
     */
    @TestVisible
    private static Map<Id, User> buildOwnerUsers(List<Case> cases) {
        if (Test.isRunningTest()) {
            Map<Id, User> forced = new Map<Id, User>();
            if (String.isNotBlank(testOwnerSignatureOverride) || String.isNotBlank(testOwnerEmailOverride)) {
                for (Case c : cases) {
                    forced.put(c.Id, new User(
                        Signature = testOwnerSignatureOverride, Email = testOwnerEmailOverride));
                }
            }
            return forced;
        }

        Map<Id, User> out = new Map<Id, User>();
        String userPrefix = User.SObjectType.getDescribe().getKeyPrefix();
        Set<Id> ownerUserIds = new Set<Id>();
        for (Case c : cases) {
            if (c.OwnerId != null && String.valueOf(c.OwnerId).startsWith(userPrefix)) {
                ownerUserIds.add(c.OwnerId);
            }
        }
        if (ownerUserIds.isEmpty()) { return out; }

        Map<Id, User> userById;
        try {
            userById = new Map<Id, User>([SELECT Id, Signature, Email FROM User WHERE Id IN :ownerUserIds]);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Owner lookup failed (falling back): ' + e.getMessage());
            return out;
        }
        for (Case c : cases) {
            User u = (c.OwnerId == null) ? null : userById.get(c.OwnerId);
            if (u != null) { out.put(c.Id, u); }
        }
        return out;
    }

    /** Best-effort HTML -> plain text (block ends -> newlines, tags stripped, entities decoded). */
    @TestVisible
    private static String htmlToPlainText(String html) {
        if (String.isBlank(html)) { return ''; }
        String t = html;
        t = t.replaceAll('(?is)<\\s*(script|style)[^>]*>.*?<\\s*/\\s*\\1\\s*>', ' '); // drop script/style
        t = t.replaceAll('(?i)<\\s*(br|/p|/div|/tr|/li|/h[1-6]|/table)\\s*/?>', '\n'); // block ends -> newline
        t = t.replaceAll('<[^>]+>', '');                     // strip all remaining tags
        t = t.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<')
             .replace('&gt;', '>').replace('&quot;', '"').replace('&#39;', '\'').replace('&apos;', '\'');
        t = t.replaceAll('[ \\t]+', ' ');                    // collapse runs of spaces
        t = t.replaceAll('(?m)^[ \\t]+|[ \\t]+$', '');       // trim each line
        t = t.replaceAll('\\n{3,}', '\n\n');                 // collapse blank-line runs
        return t.trim();
    }

    @TestVisible
    private static String loadFromAddress() {
        if (Test.isRunningTest() && testFromAddressOverride != null) { return testFromAddressOverride; }
        Support_Draft_Setting__mdt s = Support_Draft_Setting__mdt.getInstance('Default');
        return (s == null) ? null : s.Reply_From_Address__c;
    }

    @TestVisible
    private class DraftBundle {
        @TestVisible Id caseId;
        @TestVisible EmailMessage email;
        @TestVisible List<EmailMessageRelation> relations;
    }

    // ---- review & send (the reviewAiDraft LWC backend) ----
    // The standard UI has no edit/send affordance for API-created draft emails, so sendDraft uses
    // Messaging.sendEmailMessage (the platform API for existing drafts). A human clicking Send in the
    // LWC is the ONLY trigger — nothing here is called by the drafting flow (never auto-sends).

    // Messaging.SendEmailResult cannot be constructed in Apex, so the seam returns an error string.
    public interface Sender {
        String send(List<Id> emailMessageIds); // null on success; first failure's message otherwise
    }
    private class ApexSender implements Sender {
        public String send(List<Id> emailMessageIds) {
            List<Messaging.SendEmailResult> results = Messaging.sendEmailMessage(emailMessageIds, false);
            for (Messaging.SendEmailResult r : results) {
                if (!r.isSuccess()) {
                    List<String> msgs = new List<String>();
                    for (Messaging.SendEmailError err : r.getErrors()) { msgs.add(err.getMessage()); }
                    return msgs.isEmpty() ? 'Unknown send failure.' : String.join(msgs, ' ');
                }
            }
            return null;
        }
    }
    @TestVisible static Sender sender = new ApexSender();

    public class DraftInfo {
        @AuraEnabled public Id emailMessageId;
        @AuraEnabled public String subject;
        @AuraEnabled public String toAddress;
        @AuraEnabled public String ccAddress;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public String htmlBody;
        @AuraEnabled public Datetime createdDate;
    }

    @AuraEnabled
    public static DraftInfo getLatestDraft(Id caseId) {
        if (caseId == null) { return null; }
        List<EmailMessage> drafts = [
            SELECT Id, Subject, ToAddress, CcAddress, FromAddress, HtmlBody, CreatedDate
            FROM EmailMessage
            WHERE ParentId = :caseId AND Status = :EMAILMESSAGE_STATUS_DRAFT
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1];
        if (drafts.isEmpty()) { return null; }
        EmailMessage em = drafts[0];
        DraftInfo info = new DraftInfo();
        info.emailMessageId = em.Id;
        info.subject = em.Subject;
        info.toAddress = em.ToAddress;
        info.ccAddress = em.CcAddress;
        info.fromAddress = em.FromAddress;
        info.htmlBody = em.HtmlBody;
        info.createdDate = em.CreatedDate;
        return info;
    }

    /**
     * Persist the agent's edits and send. null = keep as-is for every field; blank To/subject are
     * rejected, blank Cc clears it. From is NOT editable (must stay the validated address).
     */
    @AuraEnabled
    public static void sendDraft(Id emailMessageId, String htmlBody, String toAddress,
            String ccAddress, String subject) {
        if (emailMessageId == null) { throw uiError('Missing draft email Id.'); }

        List<EmailMessage> drafts = [
            SELECT Id, Status, HtmlBody, ToAddress, CcAddress, Subject
            FROM EmailMessage WHERE Id = :emailMessageId LIMIT 1];
        if (drafts.isEmpty()) { throw uiError('The draft email no longer exists.'); }
        EmailMessage em = drafts[0];
        if (!EMAILMESSAGE_STATUS_DRAFT.equals(em.Status)) {
            throw uiError('This email is not a draft anymore — it was probably already sent.');
        }

        Boolean dirty = false;
        if (String.isNotBlank(htmlBody) && !htmlBody.equals(em.HtmlBody)) {
            em.HtmlBody = htmlBody;
            em.TextBody = htmlToPlainText(htmlBody);
            dirty = true;
        }
        if (toAddress != null) {
            if (String.isBlank(toAddress)) { throw uiError('The To address is required.'); }
            if (!toAddress.trim().equals(em.ToAddress)) { em.ToAddress = toAddress.trim(); dirty = true; }
        }
        if (subject != null) {
            if (String.isBlank(subject)) { throw uiError('The subject is required.'); }
            if (!subject.trim().equals(em.Subject)) { em.Subject = subject.trim(); dirty = true; }
        }
        if (ccAddress != null) {
            String newCc = String.isBlank(ccAddress) ? null : ccAddress.trim();
            String oldCc = em.CcAddress;
            if (newCc != oldCc) { em.CcAddress = newCc; dirty = true; }
        }

        if (dirty) {
            try {
                update em;
            } catch (Exception e) {
                throw uiError('Could not save your edits: ' + e.getMessage());
            }
        }

        String sendError = sender.send(new List<Id>{ em.Id });
        if (sendError != null) {
            throw uiError('Send failed: ' + sendError);
        }
    }

    // AuraHandledException surfaces as "Script-thrown exception" unless the message is also set.
    private static AuraHandledException uiError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}
