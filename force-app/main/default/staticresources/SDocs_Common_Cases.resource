Case #,Issue / Question,Answer / Response Provided,Answer / Response Provided by Gitbook (JUNE),Answer / Response Provided by Gitbook (APRIL 8th)
30617,How do I make the attachment field visible under Other Email Settings in my S-Docs template so I can automate file attachments?,Provided article and syntax code; emailed client with information and articles on how to create a button and automate file attachment by default,"The attachment controls do not belong under Other Email Settings.

Use Document Options → Attachment & File Options instead. There you can enable:

Create Salesforce Attachment and link to record

Create Salesforce Attachment only when emailed

Create Salesforce File and link to record

If you want attachments to be created only when the document is emailed, use Create Salesforce Attachment only when emailed. That is the setting for automating file attachment behavior.

Other Email Settings only includes:

Email domain restriction

Translate Email Settings Data

Lock Body

So if the attachment field is missing in Other Email Settings, that is expected.

Check Document Options Tab for the file settings, and Email Settings Tab for the email-only options.","The field appears when you configure it on the Email Settings tab and save the template.

In Template Editor → Email Settings → Other Email Settings, add a value to the attachment-related field and save. The docs also note the “Locked + Blank = Hidden” rule: if a field is locked and left blank, it disappears from the end-user email page. So if the attachment field is missing, check whether it’s locked with no default value.

For automated file attachments, also use the template’s attachment options under Document Options → Attachment & File Options. There you can choose:

Create Salesforce File and link to record

Create Salesforce Attachment and link to record

Create Salesforce Attachment only when emailed"
30618,SDOC__SDTemplate__c error affecting multiple orgs when accessing template— how do I fix this?,Client upgraded; they were hit with lacking permission sets,"That error usually means the template’s error flag is stuck after migration.

Use the Fixing Template Errors After Template Migration process:

Check which templates are flagged:

SELECT Id FROM SDOC__SDTemplate__c WHERE SDOC__Has_Error__c = true
Toggle SDOC__Has_Error__c off and on again with Apex.

Test the template again.

The documented Apex helper is:

public class HasErrorToggler {
    public static void toggleBooleanField(List<SObject> records, String fieldName) {
        if (records == null || records.isEmpty()) return;

        for (SObject rec : records) {
            Boolean currentValue = (Boolean) rec.get(fieldName);
            rec.put(fieldName, currentValue == null ? true : !currentValue);
        }
        update records;
    }
}
Then run:

List<SDOC__SDTemplate__c> temps = [
    SELECT Id, SDOC__Has_Error__c
    FROM SDOC__SDTemplate__c
    WHERE SDOC__Has_Error__c = true
];
HasErrorToggler.toggleBooleanField(temps, 'SDOC__Has_Error__c');
If some templates still error, check for the other documented causes:

an invalid Preview ID

a missing component the template references

a missing Related To Type option

a misconfigured lookup on the S-Doc Relationship object

See Fixing Template Errors After Template Migration and When I Open the Template Editor I Receive an Attempt to De-Reference a Null Object Error for the related checks.","SDOC__SDTemplate__c access errors after migration are usually fixed by re-saving the affected templates.

If the templates were migrated from another org, first check whether SDOC__Has_Error__c = true on those records. The docs recommend toggling that field back to false with Apex, then testing generation again. If the issue is broader, you can also re-save all active templates with a bulk update or the provided Apex/VF bulk resave flow. See Fixing Template Errors After Template Migration and Resaving Templates.

Use the error toggle first if only some templates fail; use bulk resave if many templates across orgs are affected."
30619,I'm getting an error when generating a document using S-Docs with the AccountPlan feature on AccountPlan v62+ — how do I resolve this?,Upgrade to access newer standard objects with S-Docs,"I cannot find information about AccountPlan v62+ in the docs.

The closest documented fixes for generation errors are:

Run a Save & Preview on the template first.

Check whether the template is flagged with SDOC__Has_Error__c = true.

If it is, toggle that field off and on again, then test generation.

If the error persists, verify the template does not reference:

an invalid Preview ID

a missing component

a missing Related To Type option

a misconfigured S-Doc Relationship lookup

Useful references:

Fixing Template Errors After Template Migration

When I Open the Template Editor I Receive an Attempt to De-Reference a Null Object Error

S-Doc Job Statuses

If you share the exact error text from Status Details, I can help narrow it down.","Generating errors on AccountPlan v62+ are resolved by clearing the template’s SDOC__Has_Error__c flag and re-testing.

If the affected templates were migrated or upgraded, the documented fix is to:

find templates where SDOC__Has_Error__c = true

toggle that field back to false

test generation again

"
30620,S-Docs suddenly stopped working on March 13th with no changes made — I can no longer send invoices or member certificates in Classic. What happened?,No resolution recorded,"I can’t confirm a March 13 S-Docs outage from the docs. For Classic send failures that start “suddenly,” the documented causes are usually session security, encryption, or a template error flag.

Check these in order:

High Assurance MFA/session security can block S-Docs jobs and cause failed or corrupted output. Set Session Security Level Required at Login to None, not High Assurance. See High Assurance with MFA Error.

If your org uses Platform Encryption, make sure the template uses normal merge fields and that Platform Encryption is enabled in Custom Settings. See How To: Display Salesforce Encrypted Fields.

If templates were migrated or started failing together, check whether SDOC__Has_Error__c is set. Toggle it off and on again, then test. See Fixing Template Errors After Template Migration.

If the issue is tied to encryption keys after a sandbox refresh, also check S-Docs Installation Error Encryption Key Unavailable.

If you share the exact Status Details or error text, I can narrow it down quickly.","The docs say High Assurance can restrict S-Docs’ asynchronous processing and cause generation to fail or produce corrupted files. A common symptom is a document job that completes badly or won’t load as PDF. The fix is to set Session Security Level Required at Login to None, not High Assurance, in the profile’s Session Settings. See High Assurance with MFA Error.

"
30623,SDOC__Email_ReplyTo__cAPI field is mismatched — how do I resolve this?,Caused by push upgrade,"SDOC__Email_ReplyTo__c is the template field for Reply-To.

Use the Email ReplyTo field on SDOC__SDTemplate__c, whose API name is Email_ReplyTo. It stores the reply-to address for outbound email. See S-Docs Objects.

If your automation is looking for SDOC__Email_ReplyTo__c, update it to the documented field name:


Copy
SDOC__SDTemplate__c.Email_ReplyTo
Also note:

Only one reply-to value is supported

If Lock Reply To is enabled and blank, S-Docs hides the field on the email screen

If you need sender control, that is handled separately in Email Settings under From

If you are mapping this in Apex or a flow, make sure you reference the template object, not a guessed field name. The same page also lists the email-related template fields, including Email_Send_To_Long and Email_Subject.

If you want, send the exact place where the mismatch appears — Apex, Flow, formula, or a template setting — and I’ll point to the correct field path.","The documented Reply-To support is the replyToEmail property on generateEmail. For template-based sending, the docs only describe configuring sender behavior in Email Delivery and Security, and the Flow email screen exposes Email From Org Wide Id plus lock options, not a Reply-To field.

If you meant a custom field or Flow mapping, use the documented replyToEmail API property instead of SDOC__Email_ReplyTo__c."
30624,"I'm getting an ""invalid ID field null"" error when executing an S-Docs link inside a Screen Flow — it works in Debug mode but not in the UI. How do I fix this?","Suggested to use flows to achieve the goal; advised to verify object ID, record ID and template ID","The fix is usually to pass a real record context into the flow.

When a flow works in Debug but fails from the UI, check these items:

Create a Text variable named recordId.

Mark recordId as Available for input.

Launch the flow from an actual record page.

Make sure the running user can access the flow and S-Docs action.

That pattern is required for record-page S-Docs flows. See Getting Started: Automate Document Generation.

If your screen uses an S-Docs component, also verify the ID mapping:

Live Edit Screen expects a valid S-Doc ID in sdocId

Document Viewer Screen expects a valid S-Doc ID in recordId

Blank or invalid IDs surface as runtime component errors. See Flow Reference.

For email screens, pass valid attachment IDs and record context too. Missing or invalid IDs can fail only in the interactive UI.

If you still hit invalid ID field null, check the Flow Fault path and confirm the variable feeding the S-Docs link is not blank before the screen runs.

If you want, I can narrow this down to Generate Document, Email Screen, or Live Edit.","In the docs, the S-Docs Flow components/actions require a populated Record Id / Base Record ID. In Debug, Flow can inherit test context. In the UI, that value is often blank, which triggers invalid ID field null. Pass the selected record into the S-Docs action, and ensure any email/template component also receives the correct Record Id. See How To: Email Editor In Flow and User Input Tutorial.

Make sure the flow does all of this:

stores the target record in a variable

maps that variable to the S-Docs action’s Object Id / Record Id

uses the S-Docs output ID for the next action, like Create PDF File from S-Doc"
30626,I'm getting an error when sending an email from the LWC component for specific users — it works for Admins but not for the Agent persona. How do I fix this?,LWC requires the user to create a task as a receipt for the email send; applied custom permission set to address the concern,"For an internal Agent persona, this is usually a permission gap, not an app defect.

For email from the S-Docs LWC, the documented minimum access is:

System permissions: Access Activities, Edit Task

Object access: Contact R/W/C/D, Task read + edit permissions

Org-wide email address: the profile must be allowed under Setup → Organization-Wide Addresses

See Minimum Access User Additional Permissions.

Also verify the user has the right S-Docs permission set:

SDocs User for standard internal users

SDocs Administrator only if they manage configuration

See Security and Permissions and S-Docs Permission Sets.

If the email uses attachments or record context, also confirm the Agent can access:

the base record

the S-Doc record

any attached file records

If the failure only happens for that persona, start by comparing their profile and permission sets with Admin. The mismatch is usually here.

If you share the exact error text from the LWC, I can narrow it further.","Your Agent persona is missing the email-sending permissions needed by the LWC.

The docs say emailing from LWC needs Access Activities, Edit Task, Contact R/W/C/D, and Task read/edit permissions fields. Also confirm the profile is allowed under Organization-Wide Addresses if you use one. See Minimum Access User Additional Permissions and Security and Permissions.

If you’re sending through the Documents (S-Docs) LWC, also make sure the user has the standard S-Docs access from the SDocs User permission set. The email flow itself still requires a valid To address. See How To: Sending Generated Documents via Email."
30627,align=leftspecified in my component loop but the text isn't aligning left — the styles menu seems to be overriding it. How do I fix this?,Sent instructions on how to fix; styles menu was still overriding left-align setting,"Use the field’s Additional Style and set the alignment there. For PDF-upload merge fields, that’s the control point for alignment, not the general styles menu.

Try this:

Copy
width:100px;text-align:left;
If the field spans a larger area, use that width instead. The alignment works best when a width is present.

If the styles menu is still winning, move the alignment into the same field definition so it applies directly to the rendered field. Styling in the template body is best for normal document text, but PDF-upload fields use their own styling layer.

Relevant guides:

How to: Center Text With PDF-Upload Merge Fields

Style Templates

If you want, I can help you rewrite the exact field syntax you’re using.","For the alignment issue, merge fields in PDF upload templates default to left alignment. If the styles menu is overriding it, set the field’s Additional Style directly, like width:100px;text-align:left;, and make sure the syntax uses semicolons. See Centering Text in PDF Upload Merge Fields and Style Templates."
30628,How do I set different header margins for the first page vs. remaining pages of a PDF when using different header content?,Explained they need to reduce existing margins in Page Settings and leverage span tags and CSS,"Use Header and Footer tabs for the different content, and use page-specific @page CSS if the header spacing itself must differ.

For header content:

Put page 1 content in Header.

Put later-page content in Header on remaining pages.

Leave Use first page header for all pages unchecked.

For different top spacing:

Define separate @page rules with different margin values.

Wrap each section in a matching <pagebody class=""..."">.

Example pattern:

Copy
<style>
@page firstPage { margin: 1.5in 1in 1in 1in; }
body.firstPage { page: firstPage; }

@page laterPages { margin: 0.75in 1in 1in 1in; }
body.laterPages { page: laterPages; }
</style>

<pagebody class=""firstPage"">
  ...page 1 content...
</pagebody>

<pagebody class=""laterPages"">
  ...remaining pages...
</pagebody>
If you only need different header text and not different margins, the header tabs are enough. If you need different spacing above the body, use the @page approach.

See:

Header And Footer Tabs

Multiple Pages with Different Page Margins

generating different headers on different pages in pdf templates

If you want, I can map this to your exact header layout.","The docs say to put the first-page and remaining-page content in the main template’s Header and Header on remaining pages sections, with Use first page header for all pages unchecked. For different margins, use <pagebody> with CSS @page rules and different classes, like parentTemplate and componentTemplate, each with its own margin"
30629,"After upgrading, the logo disappeared from some of my documents — the files are saved in the S-Docs folder but not the Files folder. How do I fix this?",Image URLs in template not correctly referencing the org; gave client feedback on how to resolve,"Your logo needs to be served as an externally available image.

If it was added from the Salesforce Documents folder, make sure the Document record has Externally Available Image checked. Images inserted from Browse Server are not automatically available outside Salesforce unless that flag is set. Images uploaded through the Upload tab are already set correctly.

Also check SDocsSettings → Stabilized URLs Checked. If the image URL redirects, enabling that setting fixes loading issues after upgrades.

What to do:

Open the logo’s Document record.

Check Externally Available Image.

Save.

If the logo URL redirects, enable Stabilized URLs Checked in SDocsSettings.

Re-generate the document.

If you want a safer setup going forward, use an uploaded image or a public image URL with the correct domain allowed in Remote Site Settings.

Relevant pages:

Insert Images

Template Settings: Complete Reference

If the logo still disappears, tell me whether it’s inserted from a Documents record, a URL, or a static resource.","The logo needs to be stored as an externally available Salesforce Document, not just in the S-Docs folder.

If you added it with Browse Server, open the image’s record in the Documents object and check Externally Available Image. That’s the documented fix when images show in the editor but not in generated docs. If you want to avoid this manually, re-upload the image through the Upload tab, which sets that flag automatically."
30630,"map<string,string>Apex method isn't executing correctly when called from an S-Docs template — how should I be calling it?",Provided demo video of how to use named query within callable apex; named query must be used within callable apex to achieve goal,"Call it through SDOC.GenerationOptions and SDOC.DocumentOptions.
A raw Map<String, String> is not the final argument.

Use this pattern:


Copy
SDOC.GenerationOptions genOptions = new SDOC.GenerationOptions();

Map<String, String> userInput = new Map<String, String>{
    'Field_1' => 'Value 1',
    'Field_2' => 'Value 2'
};

genOptions.documentOptions = new SDOC.DocumentOptions(userInput);

String result = SDOC.DocumentSDK.generateDocument(templateId, recordId, genOptions);
That is the supported runtime user-input flow for generateDocument. It works with a template and base record, and the values in the map populate the merge fields at generation time.

If you are generating in bulk, generateDocsInBatch does not use that map pattern. It takes recordIds, templateIds, batchSize, and optional batch actions instead.

Relevant page: Method: generateDocument (Modern)

If you want, I can show the exact call for your template type: single document, batch, or email.","Use SDOC.UserInput entries, not a raw Map<String,String> in the template.

In S-Docs, user input is passed as a collection of Apex-defined SDOC.UserInput objects with mergeField and value, then supplied to SDOC.DocumentOptions(userInput) before calling generateDocument or generateDocument-style actions. The template must contain matching merge field labels, like {{!textEntry}}. See SDK Testing and User Input Tutorial."
30631,"I'm getting an ""SDocs License Has Expired"" error when editing my template and I'm on the free version 4.416 — how do I resolve this?",Suggested to upgrade to latest version,"SDocs License Has Expired on 4.416 uses the legacy license-key flow.

Fix it by renewing the key in the special License Key template:

Open S-Docs.

Go to S-Docs Templates.

Find License Key.
If needed, switch to All Inactive Templates.

Open the record and click Edit.

Paste the new license key into Document Version.

Save.

A successful update shows ***KEY ACCEPTED*** in Document Version.

If users still cannot edit the template, give them read access to that License Key template with a sharing rule on Sdoc Template. That record is used when users generate or save templates.

Relevant pages:

How to Install & Renew Your S-Docs License Key (Legacy)

Creating a Sharing Rule for License Key Template

If you’re actually on the newer subscription model, license keys are not used there.","You need to update the legacy license key template.

For legacy S-Docs versions, the docs say to open S-Docs Templates, find the License Key Template (often under All Inactive Templates), edit it, and replace the Document Version value with the new license key. After saving, it should show ***KEY ACCEPTED***."
30632,Superscript characters in rich text fields are not rendering correctly in my DOCX template — how do I fix this?,Issue with RTF in DOCX inserting new lines resolved in S-Docs 8.0.39 patch release,"Use triple braces for the rich text field, and keep the superscript in the source content itself.

For DOCX, rich text formatting is preserved with:


Copy
{{{!Object.Rich_Text_Field__c}}}
That preserves HTML formatting, including bold, links, lists, and other rich text markup. DOCX also depends on Word-native formatting, so the .docx file should be edited and saved in Word, then reuploaded after each change.

If superscript still renders wrong:

remove any Word proofing or markup artifacts from the template file,

save and reupload the latest .docx,

and if the text includes special characters, enable Template contains international characters (Unicode fonts) and choose an appropriate Unicode enforcement level.","Use triple braces for the rich text merge field, or type=""rtf"" in a table column.

{{{!Opportunity.Description__c}}} preserves rich text formatting, including superscript, in PDF and DOCX. If the field is inside a related list, use <column type=""rtf"">Rich_Notes__c</column>. If formatting still looks wrong, check the rich-text cleanup guidance in How to Work with Rich Text Fields.

If you’re seeing other rich-text issues in DOCX, the docs also note that rich text can behave oddly in Lightning-saved fields, so you may need to normalize the field HTML first."
30633,System.LimitException: Too many SOQL queries: 101error when sending a document via email — how do I resolve this?,Same email used across 100+ Contacts causes SOQL limit issue; patch sent,"This is a Salesforce governor-limit issue. The documented fix is to reduce the number of records processed in one transaction.

If you send through Batch SDK, lower the batch size. The batch-generation guidance calls out the same limit issue and recommends keeping each batch smaller. If your template also uses document actions, remove them or clone the template first — Batch SDK does not support document actions there.

A practical path:

Reduce the batch size.

Retry the send.

If document actions are involved, test with a copy of the template that has none.

Relevant pages:

Batch SDK Doc Generation Using Batch Apex

How To: Sending Generated Documents via Email

If this is happening from a record page or Flow instead of Batch Apex, tell me which send path you use.","For Too many SOQL queries: 101 during email send, the docs point to template complexity / batch size limits. Reduce the number of records processed at once, or simplify the template’s related lists and actions. The batch guidance notes that SOQL-limit errors are resolved by limiting records in a single batch. See Batch SDK Doc Generation Using Batch Apex."
30634,How do I resend a signature request or send a reminder to pending signers who haven't signed yet?,Provided information on how to setup notifications and reminders; educated client on S-Sign notification settings,"Send a Reminder from the S-Sign Envelope record. That generates a fresh, active signer link for the pending signer.

For automatic follow-up, enable Reminders on the template and turn on the S-Sign Notifications job. The job checks pending envelopes and sends reminder emails on the schedule you set.

What to do:

Open the Salesforce record that created the request.

Go to the S-Sign Envelopes related list.

Open the pending envelope.

Send Reminder for the signer who still needs to act.

If you want reminders to happen automatically:

Enable Notifications in S-Sign Setup.

Set reminder timing in the template’s Expiration and Reminder Settings.

In v12.0+, you can also tune the Notifications Batch Size.

Relevant pages:

Signer Authentication

How To: Reminders and Expirations

Reminder and Expiration Settings

If you want, I can also show the exact setup for automatic reminders.","You can resend it from the S-Sign Envelope record by sending a Reminder.

If the signer is still pending, the reminder sends a fresh, active link to that recipient. For automated follow-ups, enable S-Sign Notifications in S-Sign Setup, then configure Reminder Emails in the template’s Expiration and Reminder Settings. See Signer Authentication and S-Sign Notifications (Setup)."
30635,A square root character is visible in the template preview but doesn't appear in the generated document — how do I get it to show?,Enabled Unicode enforcement on template settings; changed font of merge field which displayed the character,"Enable Unicode support on the template, then use a font that supports the symbol.

Open Document Options.

Check Template contains international characters (Unicode fonts).

If it still does not render, raise Unicode enforcement level from None to Data or Strict.

Use a font with broad Unicode coverage, such as Arial Unicode MS, Arial, Calibri, Tahoma, Verdana, or Times New Roman.

For PDF output, font choice matters as much as the Unicode setting. Arial Unicode MS is the only multibyte font available in Salesforce PDF rendering, but it does not reliably support bold or italic styling. If only part of the template needs the symbol, apply the Unicode font just to that section.

See:

How to Handle International Characters

Supported Fonts in PDF Format

If you want, I can help you pick the right setting for PDF or DOCX output.","n your template, go to Document Options > Other Options and check Template contains international characters (Unicode fonts). If that still doesn’t work, increase the Unicode enforcement level to Data or Strict. The docs also call out Arial Unicode MS as the multibyte font with the best extended character coverage. See Template Formatting and Design and Supported Fonts in PDF Format."
30637,"My PDF looks correct in the component before sending for signature, but the formatting is stripped out after signing — how do I fix this?",Move CSS from the component to the parent template,"Use PDF-Upload for the source PDF if you need the final signed file to keep the original layout. It renders the uploaded PDF as a static background image, so the signed output preserves the formatting exactly.

If the issue is the signature or signer text itself, check the S-Sign settings instead:

Adjust SSign__Signature_Image_Scale__c for signature size.

Set SSign__Text_To_Signature_Font__c for the signer text font.

If you added styling through PDF-Upload S-Sign fields, put it directly in the field syntax with AdditionalStyle. The UI Additional Styling box does not apply at generation.

Also note that the completed envelope produces a signed PDF plus an audit PDF, so the final file can differ from the pre-sign preview. See How S-Sign Generates Envelopes and S-Sign with PDF-Upload.

If you want, I can point you to the exact setting for your current template flow.","Move the CSS into the parent PDF template, not inside the component.

For standard PDF templates, styling is safest in the main template’s <style> block or inline markup. The docs also note that PDF output relies on Salesforce PDF rendering and that basic HTML/CSS patterns are the most reliable. See Style Templates and Adding Headers & Footers from Components in PDF Templates.

If you’re using a PDF-Upload component, keep the parent and component tags properly closed, and remember the component must use componentType=""pdf-upload""."
30638,I'm getting an error when trying to save a component that has a special character (T&C) in the template name — how do I resolve this?,Special character in component template name caused the issue,"Use a plain template name and reference it exactly.

Component names are case-sensitive in merge syntax, and the docs only show alphanumeric names in examples like {{{{!Opportunity Pricing Component}}}}. I don’t see support documented for & in component template names. The safest fix is to rename T&C to something like T and C or TC, then update every parent reference to match exactly.

If the name appears inside generated XML or another encoded block, escape punctuation there instead. For apostrophes, the documented pattern is:


Copy
<column replaceAll=""#QUOT#,&#39;"" prefix=""<template paramIn='"" postfix=""'>componentTemplateName</template>"">name</column>
See Component Template Reference Guide for the exact component syntax.

If you want, I can help you verify the parent merge field name you should use after renaming.","The docs don’t document & in component template names directly.

Component merge fields must match the template name exactly and are case-sensitive. The docs also call out that special characters can break merge fields, and they show escaping values with replaceAll for apostrophes. For a T&C name, the safest fix is to rename the component to a plain name like TC or Terms and Conditions, then reference that exact name in the merge field."
30639,"The S-Sign email link is opening in a browser instead of the Salesforce mobile app, and some users are also seeing a cipher decryption error — is mobile signing supported?",Signing in the Salesforce app is not supported; investigating the decryption error,"I cannot find information about mobile signing support or a cipher decryption error in the docs.

What is documented is that each signer gets a unique email link, and that link opens a Salesforce-hosted signing site in the browser to complete signing. The signing flow is not described as running inside the Salesforce mobile app. See Signer Authentication and Manage Delivery & Signing Experience.

For the decryption error, the docs only mention redirect-based authentication setups such as SSign.AuthenticationRedirect for CAC/PIV flows. See CAC/PIV Verification. If that matches your configuration, check that redirect setup first.

If you need a definitive answer on mobile support or the cipher error, contact support with the exact error text and the sign-flow setup.","The docs show S-Sign opens a Salesforce-hosted browser flow, not the mobile app."
30640,I can't apply CSS font-size styling to a SOQL-generated related list table — how do I style it properly?,Provided examples and answers on related list styling,"Use the generated related-list CSS class, not a generic table rule.

For direct SOQL related lists, S-Docs styles the table from the <class> value and the matching selectors like:


Copy
table.table876 { ... font-size:10pt; ... }
.table876col0 { ... font-size:10pt; ... }
.table876RowEven { ... }
.table876RowOdd { ... }
So if your table class is table1, set the font size on:

table.table1 for the whole table

.table1col0, .table1col1, etc. for specific columns

.table1RowEven and .table1RowOdd for row styling

That is the supported pattern for related list tables. A plain font-size rule outside those selectors usually won’t affect the generated table. See Related List Tables and CSS and Related List Structure.

Example:


Copy
table.table1 {
  font-size: 8pt;
  font-family: Arial, Helvetica, sans-serif;
}

.table1col0,
.table1col1,
.table1col2 {
  font-size: 8pt;
}
If you want, I can show the exact CSS block for your current table### class.","Use the generated table class selectors, not generic CSS.

The docs say S-Docs styles related lists through the table class from <class>, like table1. Use selectors such as table.table1, .table1col0, and row classes like .table1RowEven / .table1RowOdd. If you want to change text size, apply font-size to those selectors, or the specific column class."
30641,Text Area fields from Salesforce aren't wrapping properly inside merge fields in my document — how do I fix the formatting?,Provided example on styling merge fields; emailed client with CSS styling guidance for PDF-Upload template,"Use breakeverynchars on the merge field, then let the template wrap naturally.

For plain text fields, this inserts break opportunities into long values:


Copy
{{!Opportunity.Long_Text_Area__c breakeverynchars=""40""}}
For longer cells or tighter layouts, lower the number. The docs also note that this works with any text field. See How To: Display Long URLs or Text Without Breaking Layout.

If you are using a PDF-Upload template, add this to the field’s Additional Style:


Copy
white-space: normal!important;
That forces wrapping at the inserted break points.

If the field is actually rich text, use the rich-text cleanup patterns instead of plain text wrapping. See Rich Text Field Formatting Considerations.

If you want, I can show the exact syntax for your template type: standard, PDF-Upload, or related list.","For long text area fields, the docs say line breaks and formatting can carry through unexpectedly. strip-html=""True"" removes formatting during merge, including page breaks, which usually fixes wrapping issues in the document"
30642,I can no longer preview my S-Sign template — it was working before but now I'm getting an error on preview. How do I fix this?,Provided patch (8.0.18) to address S-Sign preview option,"Set a valid Preview ID first, then verify the record is accessible to your user.

Preview depends on a real Salesforce record ID in Advanced Options. It must be a valid 15- or 18-character ID for the template’s base object. Preview also uses the current user’s permissions and sharing rules, so an inaccessible record can fail even when the template itself is fine. See How to Set Up Template Preview and Advanced Options Tab.

Check these points:

Preview ID is populated and points to the correct record type.

The user opening preview can read that record.

If the template was migrated, confirm there are no broken references to missing components or invalid preview settings. See Fixing Template Errors After Template Migration.

Preview only renders the document. It does not test email delivery, file naming, or attachment creation.

If the error continues, send the exact preview error text and the template’s base object. I can help narrow it down from there.","Set a valid 15- or 18-character Salesforce record ID in Preview ID, then click Save & Preview again. The docs also say preview failures can happen when the template has been marked with an error, often after migration or when a component no longer exists. Re-save the template, then test with a real record. "
30643,My subscription was suspended — how should I handle file retention for documents that were already generated?,Provided some thoughts on file retention,"Keep the generated documents in Salesforce Files or Attachments, and make sure Delete related Salesforce Attachment/File upon S-Doc deletion is cleared if you need them to remain after the S-Doc record is removed. That setting controls whether the generated file is deleted with the S-Doc record. If it stays enabled, deleting the S-Doc deletes the related file too. See How to Auto-Attach Documents to Records and Document Options Tab.

For already generated documents:

If they were saved as Salesforce Files, they remain linked to the record unless deleted.

If they were saved as Attachments, the same retention rule applies.

If you want long-term preservation, prefer Create Salesforce File and link to record for future generations.

A practical retention setup is:

Generate documents as Files.

Leave the delete-on-S-Doc-deletion box unchecked.

Verify the file still appears in the record’s Files related list.

I couldn’t find any separate subscription-suspension retention policy in the docs. If you need account-specific guidance, contact support.","The docs say generated documents can be stored as Salesforce Files or Attachments, and you can preserve them by unchecking Delete related Salesforce Attachment/File upon S-Doc deletion in Document Options. That protects the stored file when the S-Doc record is deleted."
30644,S-Sign reminder emails are being sent from the user's email address instead of the requester's or the org default — how do I change the sender?,Explained how to set the sender address; advised client to upgrade,"Set the sender in S-Sign Setup, not in the notification template.

For reminder and expiration emails, the docs state the scheduled S-Sign Notifications Job sends mail from the user who scheduled the job. So if it’s using the wrong user address, reschedule the job as the intended internal user. See The S-Sign Notifications Job.

If you want a shared company sender, configure the org-wide address in S-Sign Setup:

Open S-Docs Setup → S-Sign Setup

Set From address for notification emails to a verified Org-Wide Address

Use Reply To Address if you want replies routed elsewhere

Save the settings

Custom notification templates cannot change From/Reply-To inside the HTML template. Those addresses come from external S-Sign settings. See Customizing S-Sign Notifications.

If you want, I can also point you to the exact S-Sign setup page section that controls the notification sender.","Set the S-Sign notification sender in Custom Settings to an Organization-Wide Address.

Reminder and expiration emails are sent by default from the S-Sign Internal User. The docs say you can change that to a generic company address by setting the Notification Email From Address to an Organization-Wide Email Address in S-Sign Custom Settings."
30645,S-Sign decline notification emails are being sent to a third recipient that I never configured — how do I fix this?,Sent client article on configuring S-Sign Notifications settings,"The extra recipient usually comes from the template’s notification party settings.

For declines, the notification is sent to the Salesforce user who initiated the request. The template can also add other parties through Parties to Notify Upon Void, Expire, or Decline and any custom recipient list. Check the template’s S-Sign Notification Settings and remove any extra parties there. See Customizing S-Sign Notifications and Template Notification Settings.

What to verify:

Parties to Notify Upon Void, Expire, or Decline

Additional recipients including audit trail

Additional recipients excluding audit trail

Any custom party list on the template

If you want the sender side standardized too, set From address for notification emails in S-Sign Setup to an Org-Wide Address. See Customize Organization Wide Settings.

If you want, I can help you map the exact field names to the setting you should clear.","The docs say Signer Declined is sent to the Salesforce user who initiated the request. If a third person is receiving it, check the template’s Parties to Notify Upon Void, Expire, or Decline setting and any Additional recipients notification settings. "
30646,"I set up zero-click signature for invoice acknowledgment, but clicking the link just refreshes the page endlessly — how do I get this working?",Provided feedback to customer on how to better achieve their use case,"Enable Zero Click at both levels, and make sure the signer experience is configured correctly.

The key requirement is the org setting Allow Zero Click Signatures in SSignSettings. The docs also mark zero-click as a feature that should not be used without S-Docs support guidance. See S-Sign Objects.

Also confirm the template is built for S-Sign:

Enable S-Sign on the PDF and HTML templates

Use the S-Sign Enabled email template path

Configure the signer link flow so the envelope is prepared, sealed, then emailed

For automated requests, the required Flow pattern is:

Generate Document

Prepare Envelope

Seal Envelope

Send Email with the signing link collection

That flow is described in Automate E-Signature Requests via Email and Automate E-Signature with Flow Builder.

If the page keeps refreshing, verify:

Allow Zero Click Signatures is checked

The template’s Zero Click flag is enabled

The signing site and public access are configured

The signer link is coming from the sealed envelope, not a generic email link

If you want, I can point you to the exact template and org fields to check first.","Use Disable Verification for that signer profile.

The docs say Disable Verification lets signers access the document immediately after clicking the link. If the link keeps looping, the signer is still being pushed through a verification step. For invoice acknowledgments, set the template’s signer profile to Disable Verification"
30647,generateDoc()that's blocking production — how do I resolve this?,Reduce excessive span tags to prevent XML depth error,"generateDocument() is synchronous and restricted to one invocation per Apex transaction. If production is blocking, move the work to generateDocsInBatch when you have volume, or keep generateDocument() to a single real-time call only. See Method: generateDocument (Modern) and Flow Reference.

What to change:

Use generateDocument() only for immediate, one-off generation.

Use Generate Documents in Batch for production fan-out.

Don’t call it inside an Apex trigger.

If the template is large, watch for heap pressure.

For Flow-based automations, the same rule applies: separate envelope steps with a transaction boundary, and avoid chaining heavy generation in one transaction.

If you’re seeing a specific error, send the exact message and where it runs — Apex, Flow, or LWC — and I’ll map it to the supported pattern.","generateDoc() failures usually come from the template, not the method itself."
30649,SDOC__Template_XML__cfield in Salesforce to retrieve template data?,Assisted client with searching the required field; provided sample SOQL query; advised to run on Sandbox first,"SDOC__Template_XML__c is only the first chunk of a template’s XML. To retrieve the full template content, query the SDOC__SDTemplate__c record and concatenate the XML chunk fields.

The template data is stored in Template XML on SDOC__SDTemplate__c, and larger templates are split across:

SDOC__Template_XML__c

SDOC__Template_XML2__c

…

SDOC__Template_XML10__c

A documented SOQL pattern looks like this:


Copy
SELECT Id, Name,
       SDOC__Template_XML__c, SDOC__Template_XML2__c, SDOC__Template_XML3__c,
       SDOC__Template_XML4__c, SDOC__Template_XML5__c, SDOC__Template_XML6__c,
       SDOC__Template_XML7__c, SDOC__Template_XML8__c, SDOC__Template_XML9__c,
       SDOC__Template_XML10__c
FROM SDOC__SDTemplate__c
WHERE SDOC__Active__c = true
Then join the non-null fields in order. The helper logic in the docs also replaces ¦ with spaces during reconstruction. See Resaving Templates and S-Docs Objects.

If you want, I can give you a ready-to-use Apex method for rebuilding the full XML string.",--
30650,"My PDF templates aren't showing up in the LWC ""Templates to Generate"" list even though the visibility settings are checked — how do I fix this?",Provided information on how to update LWC to display desired templates,"The usual fix is to check the template object match first.

For Generate Documents (S-Docs), the list only shows templates that use the same base object as the record page. Also verify the component’s Object API Name matches that object exactly. See S-Docs LWC Reference and Configure Document Generation On Your Record Page.

Check these items:

The PDF template’s Related To Type matches the record object.

The template is marked Available For Use.

The user has access to the template.

The LWC Object API Name is set before other properties.

You saved and activated the Lightning page.

If this is in Experience Cloud, also share the S-Docs objects and assign the managed permission set:

SDOC__SDTemplate__c

SDOC__SDoc__c

SDOC__SDRelationship__c

SDocs LWC Community User

Those are required for templates to appear for community users. See Adding S-Docs to Customer Portals (Experience Cloud).

If you want, I can help you narrow it down to the exact missing setting.","The docs say the Generate Documents (S-Docs) list only shows templates for the same base object as the record page. Check these items:

The template’s Related To object matches the record page object.

The component’s Object API Name matches that same object.

The template is marked Available For Use.

"
30653,How do I apply Helvetica font only when the email client is Outlook? S-Docs is applying it across all email clients.,!--[if mso]) are not possible within Salesforce,"You can’t target Helvetica only for Outlook with S-Docs email templates.

The email body supports HTML/CSS, but the docs only describe global sender, recipient, and body settings. They do not document client-specific CSS targeting for Outlook. For email templates, use a font choice that works everywhere, and set it in the template body or shared email styles. See HTML Email Templates and Email Settings Tab.

If you’re seeing Helvetica applied across all clients, that matches normal template behavior:

From, To, and Reply To are controlled in Email Settings

body styling is applied to the whole template

there’s no documented Outlook-only font switch

If you need consistent rendering, use a broadly supported fallback font in the email body. For PDFs, Helvetica is not a supported Salesforce PDF font-family value; sans-serif is the documented fallback. See Supported Fonts in PDF Format.

If you want, I can help you rewrite the template CSS so it degrades cleanly across email clients.",--
30654,My generated S-Docs files are auto-downloading without a file extension — how do I fix this?,Recent Chrome/OS update causes filenames to be cut off after commas; reformat DocumentDate in filename field to omit the default comma,"Set the filename in Document Options → Attachment & File Name Options → Output File Format.

That setting controls the generated file name. Use a value that includes the extension, like:


Copy
{!Opportunity.Name}.pdf
The docs also note to use single braces in filename formulas. If you omit the extension, the file can download without one. See Document Options Tab and How to Create Dynamic File Names.

What to check:

The template has an explicit extension in Output File Format

The generated format matches the extension, like .pdf or .docx

You saved the template after changing the setting

For modern setups, generated documents are saved as Salesforce Files and linked to the record. See How to Auto-Attach Documents to Records.

If you want, I can help you build the exact file-name formula for your template.","Generated DOC/DOC-NEW files can show a non-DOC default extension by design.

S-Docs says these outputs are not true binary DOC files. They’re HTML-based files that Word can still open. Because of that, Word may suggest a different default extension. Users can still choose .doc manually when saving, and it will work normally
S-Docs styling is applied in the template body with CSS, inline styles, or template settings. The docs only describe generic styling rules, not client-detection rules for Outlook versus other email clients."
30663,"I have two related lists for the same object with different filters, but the last table's filter is being applied to both — how do I fix this?",lineitemstags for multiple related lists,"Use separate <lineitemsSOQL> blocks for each related list.

The last filter is being reused because legacy <lineitems> blocks can apply one filter to both lists when the same related list appears twice. With <lineitemsSOQL>, each list gets its own SOQL query, so its own WHERE, ORDER BY, and LIMIT. See Use lineitemsSOQL for multiple filtered related lists.

Pattern:


Copy
<lineitemsSOQL>
  <soql>SELECT Name FROM Child__c WHERE Status__c = 'Open' ORDER BY CreatedDate DESC</soql>
  ...
</lineitemsSOQL>

<lineitemsSOQL>
  <soql>SELECT Name FROM Child__c WHERE Status__c = 'Closed' ORDER BY CreatedDate DESC</soql>
  ...
</lineitemsSOQL>
A few checks:

Convert each repeated related list from <lineitems> to its own <lineitemsSOQL>.

Put the filter in the query, not only in the layout logic.

Keep each block’s WHERE clause unique.

If you also need sorting or row limits, add them per block. The related list query runs directly during generation, so each block stays isolated. See Related List Structure.

If you want, I can help rewrite your two related-list blocks into working lineitemsSOQL syntax.","Use lineitemsSOQL instead of lineitems for both tables.

The docs call this a known limitation of lineitems related lists: when multiple related lists use different WHERE clauses, they can all inherit the same criteria. Switching each table to direct SOQL lets each one keep its own filter. Also use the object name, not the relationship name, and add a WHERE clause tied to the current record."
30664,limit 1to one related list is applying the limit to ALL related lists in the template — how do I limit just one?,Use Direct SOQL query instead; provided articles,"Use <lineitemsSOQL> for the one list you want to limit.

When related lists use legacy <lineitems> blocks, a limit can spill across repeated lists. With <lineitemsSOQL>, each related list runs its own query, so LIMIT 1 only affects that block. See Use lineitemsSOQL for multiple filtered related lists and Related List Structure.

Use this pattern:


Copy
<lineitemsSOQL>
  <soql>
    SELECT Name, Amount
    FROM Child__c
    WHERE Status__c = 'Open'
    ORDER BY CreatedDate DESC
    LIMIT 1
  </soql>
  ...
</lineitemsSOQL>

<lineitemsSOQL>
  <soql>
    SELECT Name, Amount
    FROM Child__c
    WHERE Status__c = 'Closed'
    ORDER BY CreatedDate DESC
  </soql>
  ...
</lineitemsSOQL>
Check these points:

Put LIMIT 1 inside the specific block’s SOQL.

Convert the other related lists to their own lineitemsSOQL blocks.

Avoid reusing the same legacy <lineitems> section for multiple tables.

If you want, I can help convert your current template snippet into isolated lineitemsSOQL blocks.","S-Docs documents this as a known limitation of lineitems related lists. When multiple related lists use that pattern, they can share the same criteria, including WHERE behavior. To limit only one list, convert that specific block to lineitemsSOQL and put LIMIT 1 inside its own <soql> query. See "
30667,System.NullPointerExceptionwhen an internal user submits an S-Sign form in production — it works fine in pre-production. How do I fix this?,Assign S-Sign license to resolve null object error for users with SSign permission set,"This usually points to a production-only S-Sign setup gap.

For Production, the docs require two extra steps that Sandbox does not:

assign SDocs and SSign licenses to the Site Guest User

configure an Organization-Wide Email Address that matches the Site Guest User email

Those steps are required for signature-request emails and signing flow behavior in Production. See Configure Global Settings and Manage User Access.

Also verify the normal signer setup:

the Salesforce Site is active

the correct Visualforce pages are added

public access was updated

the internal user has the SSign User or SSign Administrator permission set

See How to: Configure S-Docs E-Signature and Manage User Access.

The quickest fix path is:

Check the Site Guest User license assignment.

Verify the org-wide from address matches the guest user email.

Re-run the signer request in Production.

If it still fails, compare the exact permission sets between pre-production and Production.

If you share the exact Apex line or stack trace text, I can narrow it to the failing setup step.","High Assurance is blocking S-Sign’s async processing in production.

Set the affected profile’s Session Security Level Required at Login to None, not High Assurance. The docs say this Salesforce setting can restrict S-Docs jobs and cause failures; a common result is generated-document or signin"
30668,I successfully installed the S-Docs package in Sandbox but the app isn't showing up in the Apps browser — how do I make it appear?,assign permissions,"Rebuild the S-Docs Lightning app and assign it to your profile.

In Sandbox, the package install does not always make the app visible in the App Launcher. The docs recommend creating a Lightning app named S-Docs in Setup → App Manager and including these navigation items:

Home

S-Docs Templates

S-Docs Jobs

S-Docs Setup

Then add the user profile on the app’s User Profiles step. See Rebuilding the S-Docs App in an Org.

If you want it near the top of the App Launcher list, also go to Setup → App Menu and drag it higher. That only affects the short list, not app access.

Also make sure the user has one of these permission sets:

SDocs Administrator

SDocs User

Those grant the access needed for the app and its tabs. See Security and Permissions and S-Docs Permission Sets.

If you want, I can help you match the exact profile and permission set combination for your user.","Setup > App Manager and create a Lightning app named S-Docs. Add Home, S-Docs Templates, S-Docs Jobs, and S-Docs Setup to the navigation items. Then, on Setup > App Menu, drag S-Docs higher if you want it in the short list. See Rebuilding the S-Docs App in an Org.

If you want, I can also point you to the exact permission sets to assign after the app appears.




"
30670,I'm on S-Docs 8.0.12 and S-Sign 7.2.4 — where can I get the latest upgrade links for sandbox and production?,Shared upgrade links,"Use the current AppExchange release links for the base package, and contact S-Docs for patch links that match your installed versions.

For the latest public releases:

S-Docs: Download Our Latest Release on AppExchange

S-Sign: Request the latest installation link from S-Docs Sales

The docs also note that major package versions for S-Docs and S-Sign must align. For your installed versions, the safest path is to request the matching patch link from S-Docs Support or your Customer Success Manager. See First Step: Installing S-Sign.

If you want, I can also point you to the exact upgrade path for sandbox first, then production.","Request the latest patch link from S-Docs Sales, your Customer Success Manager, or S-Docs Support.

The docs say S-Sign is not on AppExchange, and S-Docs and S-Sign package versions must align. For your current versions, ask for the patch links that match your org’s existing version. Install in Sandbox first, then use the corresponding "
30672,"After upgrading, the screen automatically moves to the parent record after a few seconds and the document is never generated — how do I fix this?",Updated template tied to button code and confirmed file creation; template had return-to-code option causing the redirect,"Disable Redirect back to record in Template Settings → Document Options → Other Options.

When that box is checked, the user is sent back to the base record after generation. Uncheck it if you want the document flow to stay on the generation page long enough to complete. See Configure Document Generation.

Also verify the Lightning page setup:

Generate Documents and Documents use the same Object API Name

Object API Name is set before other properties

The page is saved and activated

That setup is required for the component flow to work correctly. See Configure Document Generation On Your Record Page and S-Docs LWC Reference.

If you still get redirected, check whether Open Preview is enabled on the template, since that changes the post-generation behavior.

If you want, I can help you identify the exact template setting to change first.","the related-list page uses autoRedirect=record to send users back to the parent record. If that behavior starts too early, remove autoRedirect=record from the URL button, or change it to a value that matches the flow you want, such as combineall or email. The docs also say autoRedirect is option"
30674,"I'm losing control of spacing between tables in DOC, DOC-NEW, and PDF formats when data fills in — how do I keep the formatting consistent?",Updated parent and both components to format properly upon generation,"Use the table-level spacing rules for all three formats: DOC, DOC-NEW, and PDF.

Apply these controls to each table:

On <td> / <th>: cellpadding=""0"" cellspacing=""0"" style=""padding: 0; margin: 0;""

On <table>: border-spacing=""0"" style=""padding: 0; margin: 0;""

Add border-collapse: collapse for inner tables when related lists repeat

Example:

Copy
<table border=""0"" cellpadding=""0"" cellspacing=""0"" style=""border-collapse: collapse; width: 99%;"">
  <tr>
    <td cellpadding=""0"" cellspacing=""0"" style=""padding: 0; margin: 0;"">...</td>
  </tr>
</table>
If spacing still expands when data fills in, check the table width. A fixed width can cause the renderer to add space to fill it. Reducing or removing that width often fixes the gaps. Also avoid nesting tables inside other tables when possible, since that creates unpredictable spacing. See Table Formatting: How-To Guide and Classic .doc Generation (DOC/DOC-NEW).

For PDF overflow, keep table widths percentage-based instead of pixel-based.

If you want, I can help you rewrite one table block into a spacing-safe version.","table-based layout with fixed spacing rules.

The docs recommend keeping everything inside basic HTML tables, using a starter style like border-collapse: collapse; border: none; and cellpadding=""0"" cellspacing=""0"". For spacing, avoid margins. Use table rows and blank cells instead, like <tr><td style=""line-height:20px;width:100%;"">&nbsp;&nbsp;</td></tr>. They also recommend percent-based widths for columns"
30675,Exporting more than ~30 S-Docs templates takes too long and fails — this is blocking our template migration. Is there a fix?,Migration speeds are entirely browser based; no control from S-Docs side,"There isn’t a documented bulk export fix.

Template migration is documented as one template export string per template from Advanced Options → Export Template. The supported flow is to generate the export string, copy it, and import it into the target org. See Template Lifecycle Management and Advanced Options Tab.

For large migrations, the docs only provide a resave workaround in chunks:

update [SELECT Id FROM SDOC__SDTemplate__c WHERE SDOC__Active__c=true LIMIT 50 OFFSET 50];

use 50-record batches to avoid locking the org

That guidance is for resaving after migration, but it shows the supported pattern for large template operations. See Resaving Templates.

What to do:

Export and import templates individually.

Split any bulk follow-up work into chunks of 50.

Recheck org-specific values after import, like preview IDs and org-wide email addresses.

If the export itself is failing, the docs do not list a separate bulk-export setting or retry option. I cannot find information about a mass export feature in the docs.

If you want, I can help you build a safe migration order for your templates.","If the export UI is failing around 30 templates, the docs imply the practical workaround is to migrate in smaller batches, then resave/import them in chunks."
30677,The LWC Generate Document component works fine for Admins but shows a red error toast with no explanation for standard users — how do I fix this?,A user needs access to all data referenced in the template to generate,"This is usually a permission gap.

Standard users need the SDocs User permission set, plus read access to the template and CRUD access to the S-Docs document objects. For document generation, the docs call out:

Base object: Read/Write

Fields: Read for merge fields

Fields: Edit if writeback is used

See Security and Permissions and S-Docs Permission Sets.

Check these first:

Assign SDocs User to the standard user.

Confirm the user can access the base object and fields used by the template.

Confirm the template is Read accessible and tied to the same object as the record page.

Make sure the Lightning page’s Object API Name matches the record object exactly, and it is set first.

If this is an Experience Cloud user, add SDocs LWC Community User and the required sharing for:

SDOC__SDTemplate__c

SDOC__SDoc__c

SDOC__SDRelationship__c

See Adding S-Docs to Customer Portals (Experience Cloud).

If you want, I can help you narrow it down to profile access, object access, or template visibility first.","assign the SDocs User permission set. The docs say LWCs also need the user to have access to the template and the base object. In Experience Cloud, S-Docs also requires sharing for SDOC__SDTemplate__c, SDOC__SDoc__c, and SDOC__SDRelationship__c. "
30680,font-weight: boldset in my CSS but the values aren't displaying in bold — how do I fix this?,Unicode and bold conflict; provided workaround,"If this is a PDF template, the usual cause is Unicode fonts.

When Template contains international characters (Unicode fonts) is enabled, S-Docs uses Arial Unicode MS for the document. In PDF output, that font does not reliably render bold or italic. See Bold and Italics with Unicode Fonts In PDF.

Fix it by:

turning off Template contains international characters (Unicode fonts) if you do not need it for the whole document

applying Arial Unicode MS only to the specific text that needs multilingual characters

keeping the rest of the template on a supported font family

For PDF rendering, Salesforce supports sans-serif, SansSerif, and Dialog as the Helvetica family. Helvetica itself is not a supported font-family value. See Supported Fonts in PDF Format.

A safe pattern is:


Copy
<span style=""font-family: sans-serif; font-weight: bold;"">Your value</span>
If the value still looks plain, check whether the text is inside a Unicode-only span or paragraph. That is the setting that usually overrides bold styling in PDF output.

If you want, I can help you isolate the exact line that needs the font change.","Arial Unicode MS is the only multibyte font, and it can behave oddly in Chrome PDF preview. They also note that bold and italics won’t display if “Template contains international characters (Unicode fonts)” is checked in rich-text scenarios. Try a standard font and verify whether Unicode fonts are enable"
30684,I'm on the free version and need mass merge from list view — is this available and how do I access it?,Informed about mass merge availability; advised client to decide how they would like to proceed,"I cannot find information about free-version access or list-view mass merge in the docs.

What is documented is that Mass Merge settings only appear when the feature is enabled in your org. You can check the template-level controls under Document Options → Mass Merge Options in Template Settings: Complete Reference.

Those settings include:

Allow user to email single consolidated document

Do not archive the single consolidated document

Do not include a page break between each document

Include a page break after every N documents

If you do not see those options, Mass Merge is not enabled for that org.

If you want, share the exact product edition name shown in your org, and I’ll look for the matching docs page.","Yes, but it’s a legacy feature and the docs recommend Batch SDK instead."
30685,"Does S-Docs support a ""View Email in Browser"" link in HTML email templates?",Most email clients already support this natively; also gave possible formula field workaround,"I cannot find a documented “View Email in Browser” link for S-Docs HTML email templates.

The email template docs only cover:

HTML body content and merge fields

default To / CC / BCC / Reply To

sender settings

locked fields and domain restrictions

See HTML Email Templates and Email Settings Tab.

For S-Sign emails, the HTML template is also focused on the signer message and the [[SIGN_LINK]] field. It does not document a browser-view link option. See Configure Signature Request Email Template.

If you want, I can check whether the feature exists in another related page or record.","Yes, but only through a custom HTML link.

The docs show S-Sign HTML templates support [[SIGN_LINK]], which you place in an anchor tag like <a href=""[[SIGN_LINK]]"" target=""_blank"">Click Here to Sign</a>. I couldn’t find any separate built-in “View Email in Browser” option"
30686,Can S-Docs dynamically shrink the font size in a merge field if the text doesn't fit on one line?,Cannot change font size dynamically based on user input; provided links to add static styling,"I cannot find any documented support for auto-shrinking a merge field’s font size to fit one line.

The merge-field docs cover formatting like format-date, format-number, and replaceAll, but not text auto-fit or responsive font resizing. See Merge Fields With Template Editor.

What is documented instead:

Use fixed CSS like font-size

Use replaceAll for cleanup

Use table and column formatting to control layout

For PDFs, keep font behavior predictable with supported fonts

If the text needs to fit better, the documented options are to:

lower the font size manually

widen the container or table cell

shorten the displayed value with merge-field logic or formatting

split long content into a separate line or field

If this is a PDF with rich text or Unicode fonts, font styling can also affect rendering. See Bold and Italics with Unicode Fonts In PDF and Rich Text Field Formatting Considerations.

If you want, I can help you find the best documented workaround for PDF, DOC, or HTML email output.","The docs only show ways to wrap or truncate/format text, like breakeverynchars, replaceAll, and width/text-align styling. For example, long unbroken text can be wrapped with breakeverynchars=""40"" in a merge field or related list column"
30687,S-Docs Flow Actions (Send S-Doc) aren't appearing as available actions in Salesforce Flow — how do I get them to show up?,Automation was not enabled for the client,"Add the action in Flow Builder → Action, then search for Send Email or Generate Document under the S-Docs namespace.

The docs show these invocable actions as available Flow actions:

Generate Document → SDOC__GenerateDocumentInvocable

Send Email → SDOC__EmailInvocable

Prepare Envelope / Seal Envelope for S-Sign flows

See Flow Reference and Send Email from Flow.

If the action does not appear, check these items:

S-Docs is installed in the org.

You added an Action, not another Flow element.

Your user can access S-Docs Apex actions.

For email flows, the action needs a valid Base Record ID and S-Docs Email Template Name or ID.

For generation, use Base Record ID and either Template ID or Template Name.

If you mean an Experience Cloud flow, use System Mode Generation (Experience Cloud) on the action. That is documented as an input on several Flow actions.

If you want, I can give you the exact action name to search for in your flow type: generation, email, or S-Sign.","The docs say to open Flow Builder → Add Element → Action and then search the S-Docs category. If the actions still don’t show, assign the appropriate S-Docs permission set and make sure the user can access the needed objects. For internal users, start with SDocs User or SDocs Administrator"
30688,"I'm getting a ""Content is blocked"" error when clicking the Generate S-Docs button — how do I resolve this?","Issue tied to networking/domain blocking on client's machines, not S-Docs; advised on IP allowlisting steps","Enable Lightning Web Security and CDN for Lightning Component framework in Setup → Session Settings.

That error usually means the Lightning component runtime is blocked by org settings. The documented fix is to turn on both settings, save, and retest the Generate S-Docs button. See Lightning Web Security and Content Delivery Network.

Also verify the record-page setup:

The Generate Documents (S-Docs) and Documents (S-Docs) components use the same Object API Name

Object API Name is set before the other component properties

The Lightning page is saved and activated

The user has access to the template and base object

Those checks are required for the component flow to behave correctly. See S-Docs LWC Reference and Generate Documents (S-Docs) Settings.

If this is an Experience Cloud site, also confirm:

SDOC__SDTemplate__c, SDOC__SDoc__c, and SDOC__SDRelationship__c are shared

the user has SDocs LWC Community User

See Adding S-Docs to Customer Portals (Experience Cloud).

If you want, I can help you check the exact setting order on the Lightning page.","Enable Lightning Web Security and the Lightning CDN.

The docs say S-Docs Lightning components can load inconsistently when those Salesforce org settings are off. Go to Setup → Session Settings, turn on Use Lightning Web Security for Lightning web components and Aura components, and enable Content Delivery Network (CDN) for Lightning Component framework. "
30689,How do I add a final totals row to a related list table in my template using parent record fields from a Quote with QuoteLineItems?,Sent feedback on achieving desired output with named query feature; offered alternative template formats,"Add the totals row manually after the related-list block.

The supported pattern is to keep the lineitemsSOQL table for QuoteLineItems, then add a final <tr> below it that uses the parent Quote merge field. The docs show this as a summary row with colspan and a parent merge field in the last cell. See How To: Add Custom Headers and Footers to Tables.

Example:


Copy
<table>
  <thead>
    <tr>
      <th>Product</th>
      <th>Qty</th>
      <th>Sales Price</th>
      <th>Total</th>
    </tr>
  </thead>
  <tbody>
<!--{{!
<lineitemsSOQL>
  <class>table1</class>
  <soql>
    SELECT QuoteLineItem.Name, Quantity, UnitPrice, TotalPrice
    FROM QuoteLineItem
    WHERE QuoteId = '{{!Quote.Id}}'
    ORDER BY SortOrder
  </soql>
  <column>Name</column>
  <column>Quantity</column>
  <column format-number=""#,###.00"">UnitPrice</column>
  <column format-number=""#,###.00"">TotalPrice</column>
</lineitemsSOQL>
}}-->
    <tr>
      <td colspan=""3"" style=""text-align:right;""><strong>Grand Total</strong></td>
      <td><strong>{{!Quote.Total_Amount__c}}</strong></td>
    </tr>
  </tbody>
</table>
Use the Quote field you want displayed in that last cell. The key is that the summary row sits outside the repeated related-list block.

If you want, I can adapt this to your exact Quote total field and table columns.","Use a normal table, then add a manual totals row after the <lineitemsSOQL> block.

The docs show this pattern on a Quote template:

render QuoteLineItem rows inside the related-list block

add a final <tr> after the block

pull the parent total from the Quote record with a merge field like {{!quote.totalprice #,###.##}}"
30691,"After a recent update, I'm getting a ""Failed to parse XML"" error in the Template Editor and Partner users can no longer generate documents — how do I fix this?",No resolution recorded,"This usually needs two fixes: resave the affected templates and restore partner-user access.

For the XML error, the supported post-upgrade fix is to resave templates. After migration or an upgrade, templates can error until they are manually re-saved. The docs also provide a chunked resave pattern for larger orgs. See Fixing Template Errors After Template Migration and Resaving Templates.

If the template is DOCX, also check for Word proofing markup. spellStart, gramStart, gramEnd, and related XML can trigger Failed to parse XML. Download the latest DOCX, remove spelling/grammar markup in Word, then re-upload it. See DOCX Generation Failure: SpellStart, GramStart, or GramEnd.

For partner users, verify Experience Cloud access:

assign SDocs LWC Community User

share the required S-Docs objects

confirm the template is read-accessible and matches the record object

See Security and Permissions and Configuring SDK for Authenticated vs. Unauthenticated Users.

If you want, I can help you choose the right resave method for a small set or a full org.","The XML error usually means the DOCX file has bad embedded Word markup.

For DOCX templates, the docs say to download the most recently uploaded DOCX, open it in Word, remove all spelling/grammar suggestions, then re-upload it. See DOCX Generation Failure: SpellStart.

For the partner-user issue, make sure they still have:

the SDocs User permission set

access to the License Key template if the org uses private sharing

read/write access to the base object and needed fields"
30696,SDOC__Has_Error__cand can't open the template editor — how do I fix this?,Confirmed non-paying customer; case closed,"SDOC__Has_Error__c usually means the template needs to be re-saved, not that the editor is permanently broken.

The supported repair path is:

Query the templates where SDOC__Has_Error__c = true.

Toggle the field back to false.

Re-test generation and then open the editor again.

See Fixing Template Errors After Template Migration.

If the Template Editor still will not open, the docs point to two likely causes:

the template’s Related To Type is missing from the org’s picklist options

the lookup field on S-Doc Relationship is misconfigured for that object

See When I Open the Template Editor I Receive an Attempt to De-Reference a Null Object Error.

What to check first:

Confirm the template’s Related To Type exists in this org

Confirm the S-Doc Relationship lookup points to that object

Toggle SDOC__Has_Error__c off, then retry the editor

If you want, I can help you identify the exact Related To Type and lookup field to verify.","SDOC__Has_Error__c means the template needs to be re-saved or repaired.

The docs say migrated templates can get stuck with SDOC__Has_Error__c = true. The fix is to toggle that field back to false with the provided Apex helper, then test generation again"
30699,INSUFFICIENT_ACCESS_OR_READONLYerror on the object ID when trying to upload or edit a DOCX template — how do I fix this?,Suggested the client to upgrade; also noted user missing Modify All and Delete permissions on Opportunities,"This is usually a permission or record-access issue.

For DOCX templates, the user needs the right S-Docs permission set and access to the template’s base object. The docs call out:

SDocs Administrator for full template editing

SDocs User for document generation

base object Read/Write

merge fields Read

writeback fields Edit

See Security and Permissions and Minimum Access User Additional Permissions.

Also verify the DOCX setup itself:

the template has the correct Related To Type

Enable New Microsoft Template Upload is on if you use the new upload flow

the file is re-uploaded after Word edits

See Build and Upload a DOCX Template.

If the error is tied to the object ID, confirm the template’s Related To Type exists in the org and the S-Doc Relationship lookup is configured correctly. That is the documented fix for related template access/editor issues. See Attempt to De-Reference a Null Object Error.

If this is a production org with seated licensing, also verify the user is assigned a license under Installed Packages → Manage Licenses.

Check those four items first, then retry the DOCX upload or editor.","For template work, the docs say users need the SDocs Administrator permission set to access the Template Editor. If you’re on a minimum-access profile, also grant the base object read/write plus field read/edit permissions for generation and writeback. If the S-Docs Template object is private, add a sharing rule so the user can read the template record. S"
30700,SDOC__SDTemplate__cwhen generating PDF membership certificates — how do I resolve it?,Error occurs when user does not have permissions assigned; provided article to assign permissions,"SDOC__SDTemplate__c is the template object. For PDF membership certificates, the fix depends on whether you are using a standard PDF template or PDF-Upload.

Check these first:

The template’s Related To Type is set to the membership object.

The template is Available For Use.

The user has read/write access to the base object and required fields.

If this is a PDF-Upload template, the format must be PDF-Upload, and the editor must be used to place fields.

For object access, S-Docs requires:

base object Read/Write

merge fields Read

writeback fields Edit

See Minimum Access User Additional Permissions and How to Auto-Fill Customer Data into Templates.

If the template editor itself fails, verify:

the object exists as a Related To Type option in this org

the S-Doc Relationship lookup is configured correctly

That is the documented fix for editor-related object errors. See Attempt to De-Reference a Null Object Error.

If you want, I can help you narrow it down to template access, object permissions, or PDF-Upload setup first.","Grant the user SDocs User or SDocs Administrator. For Minimum Access profiles, also give the base object R/W plus field read/edit permissions for merge fields and writeback. If templates are private, add a sharing rule for the S-Docs Template object so the user can read the template record. If this is in Experience Cloud, also share SDOC__SDTemplate__c, SDOC__SDoc__c, and SDOC__SDRelationship__c"
30701,"In a 6-signer process, the first 5 signers completed successfully but the last (counter signer) is getting an authorization error — how do I fix this?",Templates too big (too many pages) for signer experience; divide them to allow them to work,"This usually means the counter signer’s Signer Profile or auth method is mismatched, not the first five signers.

Each signer gets a unique link tied to a specific Signer Profile. The last signer must have the right email, signing order, and verification settings on that profile. Check the template’s signer routing and make sure the counter signer field is assigned to the correct profile. See Setup multi-Signer Routing Rules and E-Signature Requests: Multiple Signers.

Verify these items:

The counter signer has the correct Signer Profile and Signing Order

Their email is populated correctly

Their auth method matches the template:

Email verification if Encrypt documents at rest is on

Disable Verification only if you intentionally want no auth

PIN or CAC/PIV only if configured for that signer profile

Disable Auto-Send to Next Signer is not blocking the handoff

Also check the S-Sign Audit Trail for the exact failing signer event and profile. That usually shows whether the error is auth-related or routing-related. See Overview: The S-Sign Audit Trail and Signer Authentication.

If you send the exact authorization error text and the counter signer’s auth type, I can narrow it down further.","Make sure the counter signer’s profile has the right email, signing order, and verification type set in the template. In S-Sign, each signer gets a unique link tied to a specific profile"
30703,SDQueue2job error in production — what's causing it and how do I fix it?,Error due to awkward UX for SDCreate on DE site causing partial SDJob repeat; provided concept for direct SDJob generation and document retrieval,"This is usually caused by a document action on the template.

In batch generation, the docs say Document Actions are not supported with Batch SDK. When one is present, Salesforce can throw a queueable-job error in Apex Jobs, especially in production. The supported fix is to remove the document action from the related list or clone the template and use the clone without the action. See SDK Batch: Too Many Queueable Jobs Added to Queue and Managing and Resolving Too Many Queueable Jobs Errors in Salesforce.

What to do:

Open the template used by the production job.

Remove any Document Action from that template.

Re-test the job.

If you need the action, clone the template and keep the clone action-free for batch use.

Check Setup → Apex Jobs for the detailed failure status.

If your process also uses Run As User inside future or batch Apex, that can fail too. The documented workaround is to avoid Run As User in that path, or split the process so Run As User runs outside future/batch execution. See Run as User Future Method.

If you want, I can help you identify whether the failing job is a template action issue or a Run As User issue.","usually caused by a Document Action on the template.

The docs say this error appears when Batch SDK or queued job processing hits a template with a document action. The fix is to remove the document action from the related list or clone the template and use the clone. If the job is failing at a different stage, check Setup > Apex Jobs and the Status Details field for the exact governor limit or error"
30708,Account.Namein a conditional expression but getting a syntax error — what's the correct way to write this?,Invalid use of single quotes in conditional expression; provided correct syntax example,"Use the full merge-field syntax inside the condition.

For a standard template, write it like this:


Copy
<!--RENDER='{{!Account.Name}}' == 'Acme' -->
  Content here
<!--ENDRENDER-->
Account.Name by itself is not valid in the expression. The field must be wrapped as {{!Account.Name}}, and the whole comparison must sit inside a RENDER block. Supported operators include ==, !=, CONTAINS, &&, ||, and parentheses. See Conditional Logic Structure and Merge Fields With Template Editor.

If this is a DOCX template, keep the same logic but wrap the tags in square brackets:

Copy
[<!--RENDER='{{!Account.Name}}' == 'Acme' -->]
  Content here
[<!--ENDRENDER-->]
For a parent relationship check, Account.Name is the correct path when the base record supports that relationship. The docs also show {{!Opportunity.Account.Name}} as the parent-record example.

If you want, send the exact condition you’re trying to build and I’ll rewrite it in valid S-Docs syntax.","Account.Name needs to be wrapped as a merge field inside the RENDER expression.

Use:


Copy
<!--RENDER='{{!Account.Name}}' CONTAINS 'Enterprise' -->
  ...
<!--ENDRENDER-->
For comparisons, the docs use the same pattern:


Copy
<!--RENDER='{{!Account.Name}}' == 'Acme' -->
  ...
<!--ENDRENDER-->
If you’re in a DOCX template, keep the same logic and wrap the tags in square brackets"
30710,The filter criteria I set for one related list table is being applied to another related list of the same object type — how do I fix this?,Changed one of the related lists to direct SOQL; resolved the issue,"Use separate <lineitemsSOQL> blocks for each table.

When you reuse the same related object with legacy <lineitems>, one filter can spill into the other table. The documented fix is to move each related list into its own lineitemsSOQL query, so each table keeps its own WHERE, ORDER BY, and LIMIT. See Use lineitemsSOQL for multiple filtered related lists and Related List Structure.

Example:


Copy
<lineitemsSOQL>
  <soql>
    SELECT Name, Amount
    FROM Child__c
    WHERE Status__c = 'Open'
    ORDER BY CreatedDate DESC
  </soql>
  ...
</lineitemsSOQL>

<lineitemsSOQL>
  <soql>
    SELECT Name, Amount
    FROM Child__c
    WHERE Status__c = 'Closed'
    ORDER BY CreatedDate DESC
  </soql>
  ...
</lineitemsSOQL>
What to change:

Replace each repeated <lineitems> section with its own <lineitemsSOQL>.

Put the filter in the SOQL, not only in layout logic.

Keep each list’s query unique.

If you want, I can rewrite your current two related-list blocks into isolated lineitemsSOQL syntax.",The issue is a known limitation of lineitems related lists.
30712,How do I pull only the most recent related list record for each unique name — is there a DISTINCT or GROUP BY equivalent in SOQL for S-Docs?,SOQL cannot do DISTINCT; suggested Apex class solution using callable Apex,"S-Docs documents GROUP BY and aggregate queries, but not a separate DISTINCT keyword for related lists.

For unique names, the documented approach is to use aggregate SOQL. Example:


Copy
SELECT Name, MAX(CreatedDate) latestDate
FROM Child__c
GROUP BY Name
ORDER BY MAX(CreatedDate) DESC
That gives one row per name, with the latest date. See Introduction to SOQL and How to: Format and Summarize a Related List.

If you need the full most-recent child record for each unique name, I cannot find a documented S-Docs pattern for that exact result. The docs only show grouped summaries and standard row queries in related lists, not a built-in “latest row per group” shortcut.

A practical documented path is:

use GROUP BY for summary output

use ORDER BY ... DESC LIMIT n when you want the newest rows overall

query a specific relationship field set in the related-list block

See How to: Filter and Sort a Related List and Related List Structure.

If you want, I can help you shape the closest documented query for your object and columns.","There’s GROUP BY for summaries, but the docs don’t show a DISTINCT-style way to return the latest row per unique name."
30713,generateDocument()callable Apex in a component isn't getting the record ID — it works when the callable Apex components are removed. How do I fix this?,generateDoc()instead,"Pass the recordId explicitly and make sure the record-page component is configured with the right Object API Name.

generateDocument(templateId, recordId, options) requires a real recordId. If your callable Apex wrapper does not forward it, S-Docs gets null. The record-page components also depend on the page context, so both Generate Documents and Documents must use the same Object API Name, and that value must be set first. See Method: generateDocument (Modern) and S-Docs LWC Reference.

Fix it like this:

In Apex, pass the current record Id into generateDocument(...).

On the Lightning page, set Object API Name on both S-Docs components.

Leave Record Id at its default if the component shows it.

Save and activate the page again.

If you are using a component query or repeated component, use the documented merge-field prefix pattern instead of relying on implicit context. That is the supported way to feed fields into a component. See Using Component Queries and Component Template Reference Guide.

If you want, I can help you rewrite the Apex call so the record Id is always passed through.","The component is not getting its own record context unless you pass it in.

Use a component query and pass the record ID as a component merge field. The docs say components inherit parent context, and the optimized query model lets you pass queried fields into the component with columnFields=""true"" and mergeFieldPrefix."
30714,I'm getting an error when trying to refresh data on a document that was already successfully generated — how do I resolve this?,Provided merge field syntax; advised to assign object level permissions and retest,"Use Refresh Data on the existing document, not full regeneration.

That action updates the existing SDoc with the latest Salesforce data and saves it as a new version. It does not re-select the template. It also does not support Runtime Prompts or Job Splitters. See How To: Refresh Document Data Within the Documents and Refresh Generated Documents with Flow.

Fix it this way:

In Documents (S-Docs), enable Show Refresh.

Make sure the refresh is run against the existing SDoc ID.

Confirm the document still matches the template’s base object.

If you need a new file instead, generate again rather than refresh.

Common failure causes:

the sdocId is blank or invalid

the action is pointed at the wrong document

the user lacks access to the generated document

the record page was not refreshed after the update

If you are using Flow, pass the generated SDoc ID into the Refresh Document Data action. The action expects the existing document record, not the base Salesforce record. See Flow Reference.

If you want, I can help you map the exact sdocId source in your page or Flow.","The docs say refresh updates the existing file and creates a new version. It does not reselect the template or fully regenerate the document. If refresh fails, check that Show Refresh is enabled on the Documents component, the document was created as a Salesforce File, and the template supports the feature. Also note that Runtime Prompts and Job Splitters are not supported. "
30716,The S-Sign setup instructions say to create a Site Label and Name — should I use different values than what's shown? I'm also getting an error.,"Error is pointing to the URL, not the name or label; provided clarification","Yes — the site name itself does not matter for S-Sign setup.

The docs show example values for creating the Salesforce Site, but they also say:

The site name itself does not matter

If only one site exists, S-Docs selects it automatically

If multiple sites exist, select the intended signer site

See Configure Global Settings and How to: Configure S-Docs E-Signature.

Use the site setup fields as follows:

Site Label — any clear label

Site Name — any valid site name

Active Site Homepage — Under Construction for the global setup page

Active Site Page — CompleteESign for the e-signature setup page

If you’re getting an error, the docs most often point to one of these:

the site is not Active

the wrong Visualforce pages are added

Lightning Features for Guest Users was left enabled

the Site URL copied into S-Sign Setup is wrong

guest-user permissions or licenses are incomplete

If you paste the exact error text, I can tell you which setup step is failing.","Use the actual Salesforce Site values for your org, not necessarily the sample text.

The docs show S-Sign Site and S_Sign_Site as examples when you create the site. What matters is that the Site Label & URL syncs the Salesforce Site created during installation, and the Site URL you enter later must be the real site URL, starting with https:// and preferably the secure.force.com URL if available. "
30718,"I'm seeing an ""Automation not enabled"" error — how do I enable Automation in S-Docs?",Feature Entitlements: Automation is not enabled; needs to be enabled in Feature Entitlements,"Enable it from S-Sign Setup Page.

S-Sign notifications are disabled by default. The docs say to open S-Docs Setup → S-Sign Setup Page and click Enable Notifications. That turns on the Apex job used for reminder and expiration automation. See Reminder and Expiration Settings.

After you enable it, the extra S-Sign Template Settings appear for notification timing and behavior. If you do not see them, the automation job is still off.

Use this path:

Open App Launcher → S-Docs Setup

Go to S-Sign Setup Page

Click Enable Notifications

Save the settings

Reopen the template settings if needed

If you are setting up the site at the same time, the S-Sign setup page is reached from the same S-Docs Setup area. See Customize Organization Wide Settings.

If the error still appears after enabling notifications, send the exact error text and I can narrow it down.","Enable the SDocs Automation permissions and org settings used by the feature.

The docs say SDocs Automation covers document generation through SDJobs using the connected app for Run As User. For that path, make sure the org has:"
30721,The Record Owner's title field from the User object isn't populating in my template — I've tried multiple merge field syntax approaches. How do I get it to work?,Created a formula field and merge field; suggested named query to retrieve data from User object,"I cannot find a documented merge field for the Record Owner’s User Title.

The docs only show standard merge-field syntax like {{!Object.Field}} and parent paths like {{!Opportunity.Account.Name}}. They also list current-user special fields such as {{!UserName}}, {{!UserEmail}}, and {{!UserDepartment}}, but not a User.Title or Owner.Title example. See Merge Fields With Template Editor and Special Merge Fields.

What is documented:

merge fields use {{!Object.Field}}

DOCX fields need square brackets: [{{!Object.Field}}]

parent record paths are supported when the relationship exists

If you need the owner’s title, the docs do not show a supported field path for it. A safe workaround is to copy the value onto the base record with a Salesforce field, then merge that field instead.

If you want, send the exact object you’re generating from, and I can check whether the docs show a related-record path for it.","Use the owner relationship path, not User directly.

The docs show merge fields use dot notation like {{!Opportunity.Account.Name}} and {{!Opportunity.Owner.Email}}. For a record owner’s title, use:


Copy
{{!YourObject.Owner.Title}}"
30722,I've hit the free plan template limit — how do I urgently upgrade my S-Docs plan?,No resolution recorded (routed to sales),"I cannot find information about free-plan upgrades or a self-serve urgent plan change in the docs.

The docs do cover product setup and template limits, but not an in-app billing or upgrade flow. If you’re blocked by the template limit, the documented path is to use the supported template formats and generation options, not a plan-change procedure. See PDF Templates and Upload Existing PDFs.

If you need the account upgraded right away, contact support or your customer team. I can help you find the right template format or migration path once the plan issue is cleared.","I can’t help with pricing or account upgrades from the docs.

The docs only cover supported Salesforce editions for S-Docs, not plan changes. They say S-Docs requires Unlimited, Enterprise, Performance, or Developer Edition, and isn’t compatible with Professional or Essentials."
30723,How can I find out how many S-Sign transactions have been sent from Salesforce over the past 12 months?,Provided information on S-Sign envelopes; advised to use Salesforce Reports and Dashboards to track,"There isn’t a documented built-in S-Sign report for a 12-month transaction count.

Each S-Sign transaction creates an S-Sign Envelope on SSign__SSEnvelope__c, and the audit trail records the request lifecycle. That gives you the record set to count. See S-Sign Objects and Overview: The S-Sign Audit Trail.

Use the envelope records as your source of truth:

Count SSign__SSEnvelope__c records

Filter by the date you care about, such as CreatedDate or completion date

Optionally filter by SSign__Status__c if you only want completed sends

A SOQL pattern would look like:


Copy
SELECT COUNT()
FROM SSign__SSEnvelope__c
WHERE CreatedDate = LAST_N_DAYS:365
If you want completed transactions only, add a status filter that matches your process.

The audit trail is helpful when you need per-request timestamps and signer events, but the docs do not show a packaged “transactions sent in the last 12 months” dashboard or report.

If you want, I can help you turn the envelope object into a Salesforce report or SOQL query for your exact definition of “sent.”","S-Sign doesn’t document a built-in 12-month transaction report.

The docs say the S-Docs Usage Metrics LWC shows e-signature request usage and limits, and it refreshes every 24 hours. For transaction-level history, S-Sign also creates S-Sign Envelope records in Salesforce, which you can review from the related record or the app. "
30724,We currently have 43 licenses and need 2 more (total 45 including 1 gratis) — how do we add them?,No resolution recorded (routed to sales),"If you already bought 45 total seats and just need to assign the extra users, add them in the licensing screen.

For Salesforce package licensing:

Go to Setup → Installed Packages

Open the package

Click Manage Licenses

Click Add Users

Select the two users and save

That is the documented path for seated licenses. See Security and Permissions and Manage User Access.

If S-Sign licensing is managed inside S-Sign, use the S-Sign license page instead:

App Launcher → S-Docs Setup → S-Sign License Page

Click Add Selected Users

You can also do this in Apex with SSign.SSLicensesController.addSSignUserLicenses(userIds). See S-Sign Licensing (Apex).

If you still only have 43 purchased seats, the docs don’t show a self-serve way to add the extra 2. In that case, you need the seat count increased first, then assign the new users.

If you want, I can help you determine whether your org uses package licensing or in-product S-Sign licensing.","Add the extra seats in Setup > Installed Packages > S-Docs > Manage Licenses.

The docs say to click Add Users, select the users who need access, then click Add. They also note you don’t have to assign all available licenses at once. If you’re on a site license, no seat assignment is needed. "
30726,SSign.Envelope.classerror when clicking Generate & Sign on a Bill of Sale in our portal — how do I resolve this?,S-Sign works when you enable S-Sign on your PDF template,"This is usually an Experience Cloud access issue, not a Bill of Sale problem.

For portal users, S-Sign signing runs through the Force.com Site guest-user experience. The docs require:

the portal user to have the right Experience Cloud license/profile

the SDocs LWC Community User permission set

the S-Docs objects shared correctly

the site guest user to have the required S-Sign permissions

See Adding S-Docs to Customer Portals (Experience Cloud), Configure Global Settings, and How to: Configure S-Docs E-Signature.

Check these first:

Assign SSign Experience Cloud User to the partner user.

Assign SDocs LWC Community User if the record page uses LWCs.

Share SDOC__SDTemplate__c, SDOC__SDoc__c, and SDOC__SDRelationship__c.

Confirm the portal site is active and the signer site permissions are in place.

For Flow-driven generation, enable System Mode Generation (Experience Cloud).

If the error appears only when clicking Generate & Sign, the record page context may be failing before S-Sign starts. The docs also warn that the site name does not matter, but the selected signer site must be correct.

If you want, I can help you narrow it to permission set, site access, or Flow/system mode first.","Make sure the Bill of Sale template is S-Sign enabled and has a valid Signer Profile.

The docs say the signing flow needs:

an HTML template with [[SIGN_LINK]]

a PDF template with Enable S-Sign checked"