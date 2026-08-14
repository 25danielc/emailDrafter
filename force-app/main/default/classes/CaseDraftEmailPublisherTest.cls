/**
 * Publish-side DML goes through the EmailWriter seam (the Draft-status insert depends on the org
 * "Enable Email Drafts" feature); the send path is stubbed via the Sender seam.
 */
@isTest
private class CaseDraftEmailPublisherTest {

    private static final String FROM_ADDR = 'support@org-routing.example';

    // ---- DML seam stubs -----------------------------------------------------------------------

    private class CapturingWriter implements CaseDraftEmailPublisher.EmailWriter {
        List<EmailMessage> emails = new List<EmailMessage>();
        List<EmailMessageRelation> relations = new List<EmailMessageRelation>();
        Integer counter = 1;
        public void write(List<SObject> records) {
            for (SObject so : records) {
                if (so instanceof EmailMessage) {
                    EmailMessage em = (EmailMessage) so;
                    if (em.Id == null) { em.Id = fakeId(EmailMessage.SObjectType, counter++); }
                    emails.add(em);
                } else if (so instanceof EmailMessageRelation) {
                    relations.add((EmailMessageRelation) so);
                }
            }
        }
    }

    private class ThrowingWriter implements CaseDraftEmailPublisher.EmailWriter {
        public void write(List<SObject> records) {
            // Only the EmailMessage (Draft) insert is gated by the feature; let relations be a no-op.
            if (!records.isEmpty() && records[0] instanceof EmailMessage) {
                throw new System.DmlException(
                    'INVALID_STATUS, operation not allowed: Email drafts must be enabled to save a draft');
            }
        }
    }

    private static Id fakeId(Schema.SObjectType t, Integer i) {
        String s = String.valueOf(i);
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '0'.repeat(12 - s.length()) + s);
    }

    // ---- fixtures -----------------------------------------------------------------------------

    private static Case seedCaseWithInbound(String subject, String customerEmail) {
        Contact ct = new Contact(LastName = 'Customer', Email = customerEmail);
        insert ct;
        Case c = new Case(Subject = subject, ContactId = ct.Id, Origin = 'Email');
        insert c;
        insert new EmailMessage(
            ParentId = c.Id, Incoming = true, Status = '0',
            FromAddress = customerEmail, ToAddress = FROM_ADDR,
            Subject = subject, MessageDate = System.now());
        return c;
    }

    private static CaseDraftEmailPublisher.Request req(Id caseId, String status, String body) {
        CaseDraftEmailPublisher.Request r = new CaseDraftEmailPublisher.Request();
        r.caseId = caseId;
        r.draftStatus = status;
        r.draftBody = body;
        return r;
    }

    private static List<CaseDraftEmailPublisher.Result> run(CaseDraftEmailPublisher.Request r) {
        return CaseDraftEmailPublisher.publish(new List<CaseDraftEmailPublisher.Request>{ r });
    }

    // ---- tests --------------------------------------------------------------------------------

    @isTest
    static void draftCreatedWithCorrectFieldsRecipientAndThreading() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Merge fields blank', 'dana@customer.example');
        Id inboundId = [SELECT Id FROM EmailMessage WHERE ParentId = :c.Id AND Incoming = true LIMIT 1].Id;

        Test.startTest();
        List<CaseDraftEmailPublisher.Result> results =
            run(req(c.Id, 'DRAFTED', 'Hi Dana, update the template field mapping and the merge fields will render.'));
        Test.stopTest();

        System.assertEquals(1, w.emails.size(), 'Exactly one draft email should be built');
        EmailMessage em = w.emails[0];

        // status / parenting / visibility
        System.assertEquals('5', em.Status, 'Draft status');
        System.assertEquals(c.Id, em.ParentId, 'Parented to the Case');
        System.assertEquals(false, em.IsPrivateDraft, 'Not private -> any agent can review/send');
        System.assertEquals(false, em.Incoming, 'Outbound');

        // content
        System.assertEquals('Re: Merge fields blank', em.Subject);
        System.assert(em.HtmlBody != null && em.HtmlBody.startsWith('Hi Dana'), 'HtmlBody renders the draft body');
        // TextBody keeps the raw plain-text draft, now followed by the (fallback) sign-off.
        System.assert(em.TextBody.startsWith(
            'Hi Dana, update the template field mapping and the merge fields will render.'),
            'TextBody leads with the raw draft: ' + em.TextBody);
        System.assert(em.TextBody.contains('Sincerely,\nThe Support Team'),
            'A sign-off is appended (fallback, since the test owner has no signature): ' + em.TextBody);

        // recipient pulled from the inbound message; sender from config
        System.assertEquals('dana@customer.example', em.ToAddress, 'To = inbound FromAddress');
        System.assertEquals(FROM_ADDR, em.FromAddress);
        System.assertEquals(FROM_ADDR, em.ValidatedFromAddress);

        // threading
        System.assertEquals(inboundId, em.ReplyToEmailMessageId, 'Reply threads under the inbound message');

        // relations: To -> Contact, From -> running user
        System.assertEquals(2, w.relations.size(), 'A To and a From relation');
        Boolean sawTo = false, sawFrom = false;
        for (EmailMessageRelation rel : w.relations) {
            System.assertEquals(em.Id, rel.EmailMessageId, 'Relation stitched to the inserted email');
            if (rel.RelationType == 'ToAddress') {
                sawTo = true;
                System.assertEquals(c.ContactId, rel.RelationId, 'To resolves to the case Contact');
                System.assertEquals('dana@customer.example', rel.RelationAddress);
            } else if (rel.RelationType == 'FromAddress') {
                sawFrom = true;
                System.assertEquals(UserInfo.getUserId(), rel.RelationId, 'From resolves to the sending user');
            }
        }
        System.assert(sawTo && sawFrom, 'Both To and From relations created');

        System.assertEquals(true, results[0].emailCreated);
        System.assertNotEquals(null, results[0].emailMessageId);
    }

    @isTest
    static void htmlBodyPreservesLineAndParagraphBreaks() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Formatting', 'dana@customer.example');
        // A realistic multi-line email skeleton: greeting, a paragraph gap, body, sign-off.
        String body = 'Hi Dana,\n\nUpdate the template field mapping.\nThen re-run the merge.\n\nThanks,\nSupport';

        Test.startTest();
        run(req(c.Id, 'DRAFTED', body));
        Test.stopTest();

        EmailMessage em = w.emails[0];
        // TextBody leads with the untouched plain text (correct for plain-text mail clients), then the sign-off.
        System.assert(em.TextBody.startsWith(body), 'TextBody leads with the raw draft: ' + em.TextBody);
        // HtmlBody turns every newline into a <br> so the composer does not collapse it into one block.
        System.assert(em.HtmlBody.contains('Hi Dana,<br>'), 'Line breaks become <br>: ' + em.HtmlBody);
        System.assert(em.HtmlBody.contains('mapping.<br>'), 'Interior line break preserved');
        // 6 <br>s from the body's own newlines, plus more from the appended sign-off.
        System.assert(em.HtmlBody.countMatches('<br>') >= 6, 'One <br> per newline in the source: ' + em.HtmlBody);
        System.assert(em.HtmlBody.contains('The Support Team'), 'Sign-off appended to HtmlBody');
    }

    @isTest
    static void htmlBodyEscapesMarkupSoItStaysLiteral() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Escaping', 'dana@customer.example');
        // A reply that legitimately contains angle brackets / ampersands must not become broken HTML.
        run(req(c.Id, 'DRAFTED', 'Use <config> & set value > 5'));

        EmailMessage em = w.emails[0];
        System.assert(em.HtmlBody.contains('&lt;config&gt;'), 'Angle brackets escaped: ' + em.HtmlBody);
        System.assert(em.HtmlBody.contains('&amp;'), 'Ampersand escaped');
        System.assert(!em.HtmlBody.contains('<config>'), 'Raw markup must not survive');
    }

    @isTest
    static void earliestInboundIsUsedAsRecipientAndThreadAnchor() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Question', 'first@customer.example');
        Id firstInbound = [SELECT Id FROM EmailMessage WHERE ParentId = :c.Id LIMIT 1].Id;
        // a later inbound (e.g. a follow-up) must NOT win
        insert new EmailMessage(ParentId = c.Id, Incoming = true, Status = '0',
            FromAddress = 'second@customer.example', Subject = 'Question', MessageDate = System.now().addHours(1));

        Test.startTest();
        run(req(c.Id, 'DRAFTED', 'reply body'));
        Test.stopTest();

        System.assertEquals('first@customer.example', w.emails[0].ToAddress, 'Earliest inbound is the customer');
        System.assertEquals(firstInbound, w.emails[0].ReplyToEmailMessageId, 'Thread anchored to the original');
    }

    @isTest
    static void noDraftReasonCreatesNoEmail() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;
        Case c = seedCaseWithInbound('x', 'cust@customer.example');

        List<CaseDraftEmailPublisher.Result> results = run(req(c.Id, 'NO_DRAFT_NO_MATCH', null));

        System.assertEquals(0, w.emails.size(), 'NO_DRAFT_* must not create an email');
        System.assertEquals(false, results[0].emailCreated);
    }

    @isTest
    static void blankBodyOnDraftedCreatesNoEmail() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;
        Case c = seedCaseWithInbound('x', 'cust@customer.example');

        List<CaseDraftEmailPublisher.Result> results = run(req(c.Id, 'DRAFTED', '   '));

        System.assertEquals(0, w.emails.size(), 'DRAFTED with an empty body must not create an email');
        System.assertEquals(false, results[0].emailCreated);
    }

    @isTest
    static void emailDraftsDisabledIsHandledGracefullyAndNoted() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CaseDraftEmailPublisher.writer = new ThrowingWriter();
        Case c = seedCaseWithInbound('Merge fields blank', 'dana@customer.example');

        Test.startTest();
        List<CaseDraftEmailPublisher.Result> results =
            run(req(c.Id, 'DRAFTED', 'Hi Dana, here is the fix.')); // must NOT throw
        Test.stopTest();

        System.assertEquals(false, results[0].emailCreated, 'Disabled feature -> no email, but no exception');
        System.assert(results[0].note != null && results[0].note.contains('Email drafts'),
            'Result note explains the failure: ' + results[0].note);

        Case after = [SELECT AI_Draft_Notes__c FROM Case WHERE Id = :c.Id];
        System.assert(after.AI_Draft_Notes__c != null
            && after.AI_Draft_Notes__c.contains('Enable Email Drafts'),
            'Failure is stamped on the Case for visibility: ' + after.AI_Draft_Notes__c);
    }

    @isTest
    static void missingInboundMessageSkipsEmail() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        // Case with no inbound EmailMessage -> nothing to address/thread to.
        Case c = new Case(Subject = 'No inbound', Origin = 'Email');
        insert c;

        List<CaseDraftEmailPublisher.Result> results = run(req(c.Id, 'DRAFTED', 'body'));

        System.assertEquals(0, w.emails.size(), 'No inbound message -> no email');
        System.assertEquals(false, results[0].emailCreated);
    }

    @isTest
    static void ownerHtmlSignatureRendersAsHtmlAndStripsToPlainText() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        // A realistic WiseStamp-style branded signature (owner's real User.Signature is rich HTML).
        CaseDraftEmailPublisher.testOwnerSignatureOverride =
            '<p>Cheers,</p><table><tbody><tr><td><img src="logo.png"></td>'
            + '<td><span>Luna Park</span><br><span>Support Engineer,&nbsp;S-Docs</span><br>'
            + '<a href="mailto:lpark@sdocs.com">lpark@sdocs.com</a></td></tr></tbody></table>';
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Signature render', 'dana@customer.example');

        Test.startTest();
        run(req(c.Id, 'DRAFTED', 'Hi Dana, here is the fix.'));
        Test.stopTest();

        EmailMessage em = w.emails[0];
        System.assert(em.HtmlBody.startsWith('Hi Dana'), 'Body still leads the HtmlBody');
        // HtmlBody carries the RAW HTML signature (rendered, not escaped)
        System.assert(em.HtmlBody.contains('<span>Luna Park</span>'),
            'Branded HTML signature is rendered as HTML in the email: ' + em.HtmlBody);
        System.assert(em.HtmlBody.contains('<img src="logo.png">'), 'Signature logo/markup preserved');
        // TextBody carries a tags-stripped, readable plain-text version
        System.assert(em.TextBody.contains('Luna Park'), 'Plain-text signature name in TextBody: ' + em.TextBody);
        System.assert(em.TextBody.contains('lpark@sdocs.com'), 'Contact retained in the plain text');
        System.assert(!em.TextBody.contains('<span>') && !em.TextBody.contains('<table>'),
            'TextBody must have no HTML tags: ' + em.TextBody);
        System.assert(em.TextBody.contains('Support Engineer, S-Docs'),
            '&nbsp; is decoded to a space in the plain text: ' + em.TextBody);
    }

    @isTest
    static void csmIsCcdWhenAccountHasOne() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        // The account's CSM. User is a setup object -> insert inside runAs to avoid MIXED_DML with the
        // Account/Contact/Case/EmailMessage DML that follows. CSM_Email__c is a formula (CS_Manager__r.Email),
        // so setting CS_Manager__c makes the publisher's Account.CSM_Email__c resolve to this user's email.
        User csm;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            csm = new User(
                LastName = 'CSM', Email = 'csm@s-docs.example',
                Username = 'csm' + DateTime.now().getTime() + '@casecloser.example',
                Alias = 'csm', TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id);
            insert csm;
        }

        Account acct = new Account(Name = 'Acme', CS_Manager__c = csm.Id);
        insert acct;
        Contact ct = new Contact(LastName = 'Customer', Email = 'dana@customer.example', AccountId = acct.Id);
        insert ct;
        Case c = new Case(Subject = 'CSM cc', ContactId = ct.Id, AccountId = acct.Id, Origin = 'Email');
        insert c;
        insert new EmailMessage(ParentId = c.Id, Incoming = true, Status = '0',
            FromAddress = 'dana@customer.example', ToAddress = FROM_ADDR,
            Subject = 'CSM cc', MessageDate = System.now());

        Test.startTest();
        run(req(c.Id, 'DRAFTED', 'Hi Dana, here is the fix.'));
        Test.stopTest();

        EmailMessage em = w.emails[0];
        System.assertEquals('csm@s-docs.example', em.CcAddress, 'The account CSM is Cc\'d on the draft');
        Boolean sawCc = false;
        for (EmailMessageRelation rel : w.relations) {
            if (rel.RelationType == 'CcAddress') {
                sawCc = true;
                System.assertEquals(csm.Id, rel.RelationId, 'Cc relation resolves to the CSM user');
                System.assertEquals('csm@s-docs.example', rel.RelationAddress);
            }
        }
        System.assert(sawCc, 'A Cc relation for the CSM was created');
    }

    @isTest
    static void noCsmMeansNoCc() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        // seedCaseWithInbound builds a Case with no Account -> no CSM -> no Cc.
        Case c = seedCaseWithInbound('No CSM', 'dana@customer.example');
        run(req(c.Id, 'DRAFTED', 'body'));

        System.assertEquals(null, w.emails[0].CcAddress, 'No account CSM -> no Cc address set');
        for (EmailMessageRelation rel : w.relations) {
            System.assertNotEquals('CcAddress', rel.RelationType, 'No Cc relation without a CSM');
        }
    }

    @isTest
    static void bulkMixOfDraftedAndNonDrafted() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c1 = seedCaseWithInbound('A', 'a@customer.example');
        Case c2 = seedCaseWithInbound('B', 'b@customer.example');
        Case c3 = seedCaseWithInbound('C', 'c@customer.example');

        List<CaseDraftEmailPublisher.Request> reqs = new List<CaseDraftEmailPublisher.Request>{
            req(c1.Id, 'DRAFTED', 'reply a'),
            req(c2.Id, 'ESCALATE', 'ignored'),
            req(c3.Id, 'DRAFTED', 'reply c')
        };

        Test.startTest();
        List<CaseDraftEmailPublisher.Result> results = CaseDraftEmailPublisher.publish(reqs);
        Test.stopTest();

        System.assertEquals(2, w.emails.size(), 'Only the two DRAFTED cases get emails');
        System.assertEquals(true, results[0].emailCreated);
        System.assertEquals(false, results[1].emailCreated);
        System.assertEquals(true, results[2].emailCreated);
    }

    @isTest
    static void fromIsTheAssignedOwnersEmailWhenPresent() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR; // CMDT fallback — must NOT win here
        CaseDraftEmailPublisher.testOwnerEmailOverride = 'engineer@sdocs.example';
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Merge fields blank', 'dana@customer.example');
        run(req(c.Id, 'DRAFTED', 'Hi Dana, fix the field mapping.'));

        System.assertEquals(1, w.emails.size());
        EmailMessage em = w.emails[0];
        System.assertEquals('engineer@sdocs.example', em.FromAddress,
            'From = the assigned engineer (case owner), not the config address');
        System.assertEquals(null, em.ValidatedFromAddress,
            'An owner address is not pre-validated; the send goes out as the user who clicks Send');
    }

    @isTest
    static void fromFallsBackToConfigWhenOwnerHasNoEmail() {
        CaseDraftEmailPublisher.testFromAddressOverride = FROM_ADDR;
        CaseDraftEmailPublisher.testOwnerSignatureOverride = '<p>Cheers,<br>Sam</p>'; // owner exists, no email
        CapturingWriter w = new CapturingWriter();
        CaseDraftEmailPublisher.writer = w;

        Case c = seedCaseWithInbound('Merge fields blank', 'dana@customer.example');
        run(req(c.Id, 'DRAFTED', 'Hi Dana, fix the field mapping.'));

        System.assertEquals(1, w.emails.size());
        EmailMessage em = w.emails[0];
        System.assertEquals(FROM_ADDR, em.FromAddress, 'Email-less owner -> CMDT reply address');
        System.assertEquals(FROM_ADDR, em.ValidatedFromAddress,
            'The CMDT address is the verified org-wide one, so it is set as validated');
    }

    // ---- review & send (getLatestDraft / sendDraft) ---------------------------------------------
    // Real DML for Case/EmailMessage setup (the org has Email Drafts enabled — the Draft-status
    // insert would throw otherwise); the actual Messaging send is stubbed via the Sender seam so
    // tests never depend on org email deliverability.


    private class StubSender implements CaseDraftEmailPublisher.Sender {
        List<Id> captured = new List<Id>();
        String errorToReturn;
        public String send(List<Id> emailMessageIds) {
            captured.addAll(emailMessageIds);
            return errorToReturn;
        }
    }

    private static Case makeCase() {
        Case c = new Case(Subject = 'Widget broken', Origin = 'Email');
        insert c;
        return c;
    }

    private static EmailMessage makeEmail(Id caseId, String status, String htmlBody) {
        EmailMessage em = new EmailMessage(
            ParentId = caseId,
            Status = status,
            Incoming = false,
            Subject = 'Re: Widget broken',
            HtmlBody = htmlBody,
            TextBody = 'plain',
            ToAddress = 'customer@example.com',
            CcAddress = 'csm@example.com',
            FromAddress = 'support@example.com');
        insert em;
        return em;
    }

    // NOTE: the platform allows only ONE Draft-status EmailMessage per case (a second insert throws
    // INVALID_OPERATION), so the SOQL's newest-first ordering is untestable — and unreachable — here.
    @IsTest
    static void getLatestDraftReturnsDraftNotSentEmail() {
        Case c = makeCase();
        makeEmail(c.Id, '3', '<p>an earlier sent reply</p>'); // '3' = Sent
        EmailMessage draft = makeEmail(c.Id, '5', '<p>the draft</p>');

        CaseDraftEmailPublisher.DraftInfo info = CaseDraftEmailPublisher.getLatestDraft(c.Id);

        Assert.isNotNull(info, 'Expected a draft');
        Assert.areEqual(draft.Id, info.emailMessageId, 'The Draft-status email is returned');
        Assert.areEqual('Re: Widget broken', info.subject);
        Assert.areEqual('customer@example.com', info.toAddress);
        Assert.areEqual('csm@example.com', info.ccAddress);
        Assert.areEqual('support@example.com', info.fromAddress);
        Assert.areEqual('<p>the draft</p>', info.htmlBody);
    }

    @IsTest
    static void getLatestDraftIgnoresSentEmailsAndHandlesNull() {
        Case c = makeCase();
        makeEmail(c.Id, '3', '<p>sent</p>'); // '3' = Sent

        Assert.isNull(CaseDraftEmailPublisher.getLatestDraft(c.Id), 'Sent email is not a draft');
        Assert.isNull(CaseDraftEmailPublisher.getLatestDraft(null), 'Null case id -> null');
    }

    @IsTest
    static void sendDraftPersistsEditsAndSends() {
        Case c = makeCase();
        EmailMessage draft = makeEmail(c.Id, '5', '<p>original</p>');
        StubSender stub = new StubSender();
        CaseDraftEmailPublisher.sender = stub;

        Test.startTest();
        CaseDraftEmailPublisher.sendDraft(draft.Id, '<p>Edited by the agent</p>',
            'other.contact@example.com', '', 'Re: Widget broken [urgent]');
        Test.stopTest();

        Assert.areEqual(new List<Id>{ draft.Id }, stub.captured, 'Draft id handed to the send API');
        EmailMessage after = [SELECT HtmlBody, TextBody, ToAddress, CcAddress, Subject
                              FROM EmailMessage WHERE Id = :draft.Id];
        Assert.areEqual('<p>Edited by the agent</p>', after.HtmlBody, 'Edited HTML persisted');
        Assert.areEqual('Edited by the agent', after.TextBody, 'TextBody regenerated from the edit');
        Assert.areEqual('other.contact@example.com', after.ToAddress, 'Edited To persisted');
        Assert.isNull(after.CcAddress, 'Blank Cc clears the Cc');
        Assert.areEqual('Re: Widget broken [urgent]', after.Subject, 'Edited subject persisted');
    }

    @IsTest
    static void sendDraftWithBlankBodySendsAsIs() {
        Case c = makeCase();
        EmailMessage draft = makeEmail(c.Id, '5', '<p>original</p>');
        StubSender stub = new StubSender();
        CaseDraftEmailPublisher.sender = stub;

        CaseDraftEmailPublisher.sendDraft(draft.Id, null, null, null, null);

        Assert.areEqual(1, stub.captured.size(), 'Sent without edits');
        EmailMessage after = [SELECT HtmlBody, TextBody, ToAddress, CcAddress, Subject
                              FROM EmailMessage WHERE Id = :draft.Id];
        Assert.areEqual('<p>original</p>', after.HtmlBody, 'Body untouched');
        Assert.areEqual('plain', after.TextBody, 'TextBody untouched');
        Assert.areEqual('customer@example.com', after.ToAddress, 'To untouched');
        Assert.areEqual('csm@example.com', after.CcAddress, 'Cc untouched');
        Assert.areEqual('Re: Widget broken', after.Subject, 'Subject untouched');
    }

    @IsTest
    static void sendDraftRejectsBlankToAndSubject() {
        Case c = makeCase();
        EmailMessage draft = makeEmail(c.Id, '5', '<p>original</p>');
        StubSender stub = new StubSender();
        CaseDraftEmailPublisher.sender = stub;

        try {
            CaseDraftEmailPublisher.sendDraft(draft.Id, null, '  ', null, null);
            Assert.fail('Expected an exception for a blank To');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('To address'), e.getMessage());
        }

        try {
            CaseDraftEmailPublisher.sendDraft(draft.Id, null, null, null, '  ');
            Assert.fail('Expected an exception for a blank subject');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('subject'), e.getMessage());
        }

        Assert.areEqual(0, stub.captured.size(), 'Nothing was sent');
    }

    @IsTest
    static void sendDraftSurfacesSendFailure() {
        Case c = makeCase();
        EmailMessage draft = makeEmail(c.Id, '5', '<p>original</p>');
        StubSender stub = new StubSender();
        stub.errorToReturn = 'No verified from address.';
        CaseDraftEmailPublisher.sender = stub;

        try {
            CaseDraftEmailPublisher.sendDraft(draft.Id, null, null, null, null);
            Assert.fail('Expected an exception on send failure');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('No verified from address.'),
                'Send error surfaced to the UI: ' + e.getMessage());
        }
    }

    @IsTest
    static void sendDraftRejectsNonDraftAndMissing() {
        Case c = makeCase();
        EmailMessage sent = makeEmail(c.Id, '3', '<p>sent</p>');
        StubSender stub = new StubSender();
        CaseDraftEmailPublisher.sender = stub;

        try {
            CaseDraftEmailPublisher.sendDraft(sent.Id, null, null, null, null);
            Assert.fail('Expected an exception for a non-draft email');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not a draft'), e.getMessage());
        }

        try {
            CaseDraftEmailPublisher.sendDraft(null, null, null, null, null);
            Assert.fail('Expected an exception for a null id');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Missing'), e.getMessage());
        }

        Assert.areEqual(0, stub.captured.size(), 'Nothing was sent');
    }
}
