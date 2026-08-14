/**
 * Table-driven coverage of every intake rule, with explicit near-miss LEGIT cases for each
 * exclusion class — precision failures (legit cases wrongly excluded) are the expensive mistake.
 */
@isTest
private class CaseIntakeClassifierTest {

    private class Tc {
        String subject; String body; String sender; String expected; String why;
        Tc(String subject, String body, String sender, String expected, String why) {
            this.subject = subject; this.body = body; this.sender = sender;
            this.expected = expected; this.why = why;
        }
    }

    private static void runTable(List<Tc> table) {
        for (Tc t : table) {
            CaseIntakeClassifier.Verdict v =
                CaseIntakeClassifier.classify(t.subject, t.body, t.sender);
            System.assertEquals(t.expected, v.category,
                t.why + ' — subject "' + t.subject + '" got ' + v.category
                + (v.reason == null ? '' : ' (' + v.reason + ')'));
            if (t.expected != CaseIntakeClassifier.CATEGORY_LEGIT) {
                System.assert(String.isNotBlank(v.reason), 'Excluded verdicts must carry a reason');
                System.assert(
                    v.reason.startsWith('Junk mail:') || v.reason.startsWith('Billing/licensing:'),
                    'Reason must carry the machine-scannable prefix, was: ' + v.reason);
            }
        }
    }

    @isTest
    static void junkRules() {
        runTable(new List<Tc>{
            new Tc('Question about templates', 'body', 'no-reply@vendor.com', 'JUNK', 'no-reply sender'),
            new Tc('Question', 'body', 'donotreply@notices.example.com', 'JUNK', 'donotreply sender'),
            new Tc('Anything', 'body', 'mailer-daemon@googlemail.com', 'JUNK', 'mailer-daemon'),
            new Tc('Anything', 'body', 'notifications@github.com', 'JUNK', 'notifications@ sender'),
            new Tc('Automatic reply: Case 00034512 update', 'I am out of office.', 'user@corp.com',
                'JUNK', 'auto-reply subject'),
            new Tc('RE: Automatic reply: your ticket', 'loop body', 'user@corp.com',
                'JUNK', 'auto-reply behind RE: prefix'),
            new Tc('Out of office - back Monday', 'ooo', 'user@corp.com', 'JUNK', 'out of office'),
            new Tc('Undeliverable: RE: your request', 'bounce', 'user@corp.com', 'JUNK', 'bounce subject'),
            new Tc('Ticket received: Case 00034471', 'We got your request.', 'support@sdocs.com',
                'JUNK', 'support ack loop'),
            new Tc('[#8MT-EX2-HMV1] Ticket received: S-Docs Support Case #: 00034085 Created',
                'Thank you for contacting us.', 'user@corp.com', 'JUNK',
                'ack loop behind a helpdesk [#REF] prefix (4 escaped in the 07-16 pinned run)'),
            new Tc('Invitation: S-Docs sync @ Tue 3pm', 'Microsoft Teams meeting Meeting ID: 123',
                'user@corp.com', 'JUNK', 'calendar invite subject'),
            new Tc('Accepted: project kickoff', '', 'user@corp.com', 'JUNK', 'invite response'),
            new Tc('Monthly newsletter - July edition', 'news body', 'user@corp.com', 'JUNK', 'newsletter subject'),
            new Tc('Join our webinar on document automation', 'promo', 'user@corp.com', 'JUNK', 'webinar promo'),
            new Tc('Quick sync', 'Microsoft Teams meeting\nJoin on your computer\nMeeting ID: 291 442',
                'user@corp.com', 'JUNK', 'invite-only body')
        });
    }

    @isTest
    static void junkNearMissesStayLegit() {
        String longBodyWithInvite = 'We keep hitting a merge field problem when generating from the '
            + 'opportunity. Steps to reproduce are below, and happy to walk through it live - I set up '
            + 'a Microsoft Teams meeting for Thursday if easier. The template uses line-item tables and '
            + 'the totals row renders blank on every run since the v11 upgrade. We tried recreating the '
            + 'template from scratch and the issue persists. Error shown: "Ending position out of '
            + 'bounds". Also attached the template XML export and two sample PDFs showing the blank '
            + 'totals row. This is blocking our quote-generation go-live scheduled for next week, so '
            + 'any guidance would be appreciated. You can also reach me on my cell. I will send the '
            + 'meeting invite separately so this thread stays focused on the technical details of the '
            + 'problem itself. Thanks so much for the help as always, and let me know if you need org '
            + 'access or a screen recording of the generation run to diagnose further.';
        System.assert(longBodyWithInvite.length() > 800, 'precondition: body exceeds invite-only size');
        runTable(new List<Tc>{
            new Tc('Reply to: merge fields blank', 'The reply from the doc generation is empty.',
                'jane@customer.com', 'LEGIT', '"reply" inside a real subject is not auto-reply'),
            new Tc('Delivery of generated documents fails', 'S-Docs delivery option errors out.',
                'jane@customer.com', 'LEGIT', 'product "delivery" is not a bounce notice'),
            new Tc('Meeting agenda template question', longBodyWithInvite,
                'jane@customer.com', 'LEGIT', 'a real question that mentions Teams is not an invite'),
            new Tc('Ticket received wrong routing?', null, 'jane@customer.com', 'LEGIT',
                'ack-loop phrasing without the ack colon is a real question'),
            new Tc('How do I get notifications about signed docs?',
                'We want notifications@ourdomain to get a copy of every signed envelope.',
                'jane@customer.com', 'LEGIT', 'notifications discussed in body, sender is human')
        });
    }

    @isTest
    static void billingRules() {
        runTable(new List<Tc>{
            new Tc('Please issue a temporary license key', 'Our license expires Friday, can you '
                + 'issue us a temporary license until the renewal completes?', 'jane@customer.com',
                'BILLING', 'the confirmed-FP shape: license issuance ask (case 00033797)'),
            new Tc('Invoice for renewal', 'Please send the invoice for our upcoming renewal.',
                'jane@customer.com', 'BILLING', 'invoice/renewal'),
            new Tc('Purchase order for S-Sign seats', 'PO attached, please process.',
                'jane@customer.com', 'BILLING', 'purchase order'),
            new Tc('Pricing question', 'What is the price list for 50 additional users?',
                'jane@customer.com', 'BILLING', 'pricing ask'),
            new Tc('Can you extend our trial', 'We need two more weeks to finish evaluation, '
                + 'please extend the trial.', 'jane@customer.com', 'BILLING', 'trial extension'),
            new Tc('Refund request', 'We were double charged last month, requesting a refund.',
                'jane@customer.com', 'BILLING', 'refund'),
            new Tc('Add additional SDocs licences', 'We need 10 more licences for the new team.',
                'jane@customer.com', 'BILLING', 'seat-count purchase (2026-07-16 fresh-cohort leak)'),
            new Tc('drop in license count', 'Our license count dropped from 50 to 40, please advise.',
                'jane@customer.com', 'BILLING', 'license-count entitlement question'),
            new Tc('Request for S-Docs Free Tier Quota Reset', 'Can our free tier quota reset early?',
                'jane@customer.com', 'BILLING', 'quota reset ask')
        });
    }

    @isTest
    static void recallNoticesAreJunkButLicenseErrorsStayLegit() {
        runTable(new List<Tc>{
            new Tc('Recall: Re: [EXTERNAL]00034155 | S-Sign Error', 'recall body', 'user@corp.com',
                'JUNK', 'Outlook message recall'),
            new Tc('How do I assign a license to a user', 'Where in Setup do I assign the S-Docs '
                + 'license?', 'jane@customer.com', 'LEGIT', 'license HOW-TO is not commerce'),
            new Tc('License key not accepted after adding users', 'After adding users the key errors '
                + 'out as invalid.', 'jane@customer.com', 'LEGIT', 'troubleshooting veto holds')
        });
    }

    @isTest
    static void billingNearMissesStayLegit() {
        runTable(new List<Tc>{
            new Tc('Invalid S-Sign license key error', 'We pasted the license key and get "invalid '
                + 'license key" when saving. What causes this?', 'jane@customer.com', 'LEGIT',
                'license ERROR is a known-error doc topic, not billing'),
            new Tc('License key not working after sandbox refresh', 'After refresh the key fails '
                + 'validation with an error.', 'jane@customer.com', 'LEGIT', 'license troubleshooting'),
            new Tc('Documents fail after renewal', 'Since our renewal, generation errors out with '
                + 'a permissions exception.', 'jane@customer.com', 'LEGIT',
                'billing word + error context = troubleshooting veto'),
            new Tc('Quote template merge fields blank', 'Our quote PDF renders blank merge fields — '
                + 'unable to figure out why.', 'jane@customer.com', 'LEGIT',
                '"quote" as a document type, not a purchasing quote'),
            new Tc('How does billing address map into templates?', 'We need the billing address '
                + 'field on the invoice template we generate — it shows the wrong value, seems like a bug.',
                'jane@customer.com', 'LEGIT', 'billing/invoice as template CONTENT with problem context'),
            // Case 00034158 shape: a "...Pricing" subject with a genuine product how-to buried in the
            // quoted reply. The product-question veto keeps it LEGIT so it can draft.
            new Tc('Re: EQD/S Docs Next Steps - Pricing', 'Thanks. > Could you remind me how to add a '
                + 'QR code inside the template? I set the URL to the QR Code URL field but it shows as a '
                + 'broken image.', 'connor@customer.com', 'LEGIT',
                'buried product how-to (QR code in template) vetoes the billing/pricing route')
        });
    }

    @isTest
    static void blankAndNullInputsAreLegit() {
        // Fail open: classification must never block drafting on missing data.
        System.assertEquals('LEGIT', CaseIntakeClassifier.classify(null, null, null).category);
        System.assertEquals('LEGIT', CaseIntakeClassifier.classify('', '', '').category);
        System.assertEquals(null, CaseIntakeClassifier.classify('Normal question', 'body', 'a@b.com').reason,
            'LEGIT carries no reason');
    }

    @isTest
    static void invocableWrapsClassify() {
        CaseIntakeClassifier.Request junk = new CaseIntakeClassifier.Request();
        junk.subject = 'Automatic reply: out of office';
        junk.description = 'ooo';
        junk.suppliedEmail = 'user@corp.com';
        CaseIntakeClassifier.Request legit = new CaseIntakeClassifier.Request();
        legit.subject = 'Merge fields blank in template';
        legit.description = 'The generated document shows blank merge fields.';
        legit.suppliedEmail = 'jane@customer.com';

        List<CaseIntakeClassifier.Result> out = CaseIntakeClassifier.run(
            new List<CaseIntakeClassifier.Request>{ junk, legit, null });

        System.assertEquals(3, out.size());
        System.assertEquals('JUNK', out[0].category);
        System.assert(out[0].reason.startsWith('Junk mail:'));
        System.assertEquals('LEGIT', out[1].category);
        System.assertEquals(null, out[1].reason);
        System.assertEquals('LEGIT', out[2].category, 'null request fails open to LEGIT');
    }
}
