/**
 * The shared vocabulary of the drafting pipeline: routed-outcome statuses, the confidence ladder,
 * Support_Solution__c visibility values, the trust-excluded source types, the draft floor, default
 * model names, and the case-mined provenance key. One definition per contract — the Apex side of a
 * rename is a one-file change here (the AutomatedEmailDrafting Flow XML still matches status
 * literals and must be touched separately).
 */
public with sharing class SupportDraftVocab {

    // ---- routed outcome statuses (Case.AI_Draft_Status__c; branched on by the Flow) ----
    public static final String STATUS_DRAFTED           = 'DRAFTED';
    public static final String STATUS_ESCALATE          = 'ESCALATE';
    public static final String NO_DRAFT_EXCLUDED        = 'NO_DRAFT_EXCLUDED';
    public static final String NO_DRAFT_NO_MATCH        = 'NO_DRAFT_NO_MATCH';
    public static final String NO_DRAFT_LOW_CONFIDENCE  = 'NO_DRAFT_LOW_CONFIDENCE';
    public static final String NO_DRAFT_UNGROUNDED      = 'NO_DRAFT_UNGROUNDED';
    public static final String NO_DRAFT_UNVERIFIED      = 'NO_DRAFT_UNVERIFIED';
    public static final String NO_DRAFT_MODEL_ERROR     = 'NO_DRAFT_MODEL_ERROR';

    // ---- confidence ladder (Case.AI_Draft_Confidence__c) ----
    public static final String CONF_HIGH   = 'HIGH';
    public static final String CONF_MEDIUM = 'MEDIUM';
    public static final String CONF_LOW    = 'LOW';
    public static final String CONF_NONE   = 'NONE';

    // ---- Support_Solution__c.Visibility__c ----
    public static final String VIS_CUSTOMER_SAFE = 'customer_safe';
    public static final String VIS_AGENT_ONLY    = 'agent_only';
    public static final String VIS_ESCALATE_ONLY = 'escalate_only';

    // Trust tiers that are never customer-reply fuel even when Visibility__c is customer_safe.
    public static final Set<String> DRAFT_TRUST_EXCLUDED = new Set<String>{ 'draft', 'internal_ops' };

    /**
     * The draft floor: below this calibrated retrieval score the pipeline never drafts. Shared by
     * retrieval's HIGH bar + distill trigger, drafting's score gate, and mining's dedupe gate — the
     * mined-doc dedupe deliberately asks "would the existing corpus already draft this?".
     * Overridable per consumer via Support_Draft_Setting__mdt.
     */
    public static final Decimal DRAFT_FLOOR = 0.45;

    // ---- default model names (each overridable via Support_Draft_Setting__mdt) ----
    public static final String MODEL_DRAFTING_DEFAULT  = 'sfdc_ai__DefaultGPT4Omni';
    public static final String MODEL_MINI_DEFAULT      = 'sfdc_ai__DefaultOpenAIGPT4OmniMini';
    public static final String MODEL_EMBEDDING_DEFAULT = 'sfdc_ai__DefaultOpenAITextEmbeddingAda_002';

    // Source_Space_Key__c provenance for case-mined docs (survives the help.sdocs reconcile;
    // the one-command rollback and the mining dedupe gate both key on it).
    public static final String SPACE_KEY_CASE_MINED = 'case-mined';

    // ---- verification-gate modes (Support_Draft_Setting__mdt.Draft_Gate_Mode__c) ----
    // block  = a failed grounding/claim/verify gate returns NO_DRAFT_* (fail-closed, the code default)
    // demote = failures stamp [NEEDS REVIEW] warnings + force LOW confidence but still DRAFT —
    //          drafts are always human-reviewed before sending, so a weak draft costs reviewer
    //          time while a blocked draft gives the reviewer nothing.
    public static final String GATE_MODE_BLOCK  = 'block';
    public static final String GATE_MODE_DEMOTE = 'demote';
}
