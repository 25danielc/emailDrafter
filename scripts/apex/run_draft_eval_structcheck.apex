/**
 * run_draft_eval_structcheck.apex — targeted re-eval of the 19 pinned cases affected by the
 * 2026-07-23 Phase-1 smoke (11 structural declines + 8 double-vote blocks), after the veto
 * refinement and the second-vote disable. Confirms: good drafts return (as clean or demoted),
 * and structural declines fire only on substance-free cases.
 */
String RUN_LABEL = 'eval-structcheck-2026-07-23';

List<Id> COHORT = new List<Id>{
    '500cW00000KWZ5ZQAX','500UW000016GisRYAS','500UW000015YWWjYAO','500UW000017M31GYAS',
    '500UW000015vbtvYAA','500UW000014jpRoYAI','500UW000012BxT1YAK','500cW00000KRjSjQAL',
    '500UW000012K02DYAS','500UW000016slKaYAI','500UW000014RcZYYA0','500UW000017UBT2YAO',
    '500UW000012VjfCYAS','500UW0000152TSOYA2','500UW000016VuEsYAK','500UW000011Y7VpYAK',
    '500UW000011Y94hYAC','500UW000014k8MNYAY','500UW000014RYRAYA4'
};

System.enqueueJob(new DraftEvalBatchJob(COHORT, RUN_LABEL));
System.debug(LoggingLevel.ERROR, 'Enqueued structcheck eval over ' + COHORT.size() + ' cases.');
