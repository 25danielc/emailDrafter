import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLatestDraft from '@salesforce/apex/CaseDraftEmailPublisher.getLatestDraft';
import sendDraft from '@salesforce/apex/CaseDraftEmailPublisher.sendDraft';

/**
 * Quick-action panel ("Review & Send AI Draft" on Case): loads the newest Draft-status
 * EmailMessage on the case, lets the agent edit the body, and sends it via Apex
 * (Messaging.sendEmailMessage). This is the only send path for AI drafts — the standard UI
 * has no send affordance for API-created draft emails.
 */
export default class ReviewAiDraft extends LightningElement {
    _recordId;
    draft;
    body = '';
    to = '';
    cc = '';
    subject = '';
    loading = true;
    sending = false;
    error;

    // recordId is set by the quick-action runtime after construction; load once it arrives.
    @api
    set recordId(value) {
        this._recordId = value;
        if (value && !this.draft) {
            this.loadDraft();
        }
    }
    get recordId() {
        return this._recordId;
    }

    async loadDraft() {
        this.loading = true;
        try {
            this.draft = await getLatestDraft({ caseId: this._recordId });
            this.body = this.draft ? this.draft.htmlBody : '';
            this.to = (this.draft && this.draft.toAddress) || '';
            this.cc = (this.draft && this.draft.ccAddress) || '';
            this.subject = (this.draft && this.draft.subject) || '';
            this.error = undefined;
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    get hasDraft() {
        return !this.loading && !!this.draft;
    }
    get noDraft() {
        return !this.loading && !this.draft && !this.error;
    }
    get sendLabel() {
        return this.sending ? 'Sending…' : 'Send';
    }
    get sendDisabled() {
        return this.sending || !this.to.trim() || !this.subject.trim();
    }

    handleBodyChange(event) {
        this.body = event.target.value;
    }
    handleToChange(event) {
        this.to = event.target.value;
    }
    handleCcChange(event) {
        this.cc = event.target.value;
    }
    handleSubjectChange(event) {
        this.subject = event.target.value;
    }

    async handleSend() {
        this.sending = true;
        try {
            await sendDraft({
                emailMessageId: this.draft.emailMessageId,
                htmlBody: this.body,
                toAddress: this.to,
                ccAddress: this.cc,
                subject: this.subject
            });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Email sent',
                    message: `The reply was sent to ${this.to}.`,
                    variant: 'success'
                })
            );
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (e) {
            this.error = this.messageOf(e); // keep the panel open so the draft isn't lost
        } finally {
            this.sending = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    messageOf(e) {
        return e && e.body && e.body.message ? e.body.message : 'Unexpected error.';
    }
}
