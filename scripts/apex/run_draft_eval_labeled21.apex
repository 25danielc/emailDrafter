/**
 * run_draft_eval_labeled21.apex — focused eval over exactly the 21 reviewer-labeled drafts from the
 * 2026-07-20b run (11 good / 10 FP, docs/eval-drafts-reviewed-2026-07-20b.csv). Fast, cheap
 * confirmation of the precision gates against the known labels. Set RUN_LABEL per experiment.
 *
 * Run: sf apex run -f scripts/apex/run_draft_eval_labeled21.apex -o vscodeOrg
 */
String RUN_LABEL = 'eval-21-gpt4o-judge';

List<Id> COHORT = new List<Id>{
    // good (11)
    '500UW000017EY3kYAG', '500UW000011lsGtYAI', '500cW00000KWZ5ZQAX', '500UW000011flEqYAI', '500UW000016lOawYAE',
    '500UW000015Zwc3YAC', '500UW000016WssbYAC', '500UW000012BxT1YAK', '500UW000013wOMHYA2', '500UW0000160Me6YAE',
    '500UW000011Y94hYAC',
    // false-positive ungrounded (4)
    '500UW000015jZ9kYAE', '500cW00000KRjSjQAL', '500UW000014RcZYYA0', '500UW000016VuEsYAK',
    // false-positive topical-but-wrong (6)
    '500UW000012DmObYAK', '500UW000011R3iJYAS', '500UW000012Ifj2YAC', '500UW000015vbtvYAA', '500UW000014jpRoYAI',
    '500UW0000152TSOYA2'
};

System.assertEquals(21, COHORT.size(), 'labeled cohort must be the 21 reviewer-labeled cases');
System.enqueueJob(new DraftEvalBatchJob(COHORT, RUN_LABEL));
System.debug(LoggingLevel.ERROR, 'Enqueued labeled-21 eval "' + RUN_LABEL + '".');
