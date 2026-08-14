/**
 * build_mining_import2.js — widened 2026-07-22 mining import (supersedes build_mining_import.js).
 *
 * Joins preprod's outbound agent replies to vscodeOrg cases by CaseNumber and emits one synthetic
 * merged outbound EmailMessage per case, tagged for one-command rollback. Differences vs the
 * 2026-07-21 build, both driven by the 07-21b run report:
 *  1. TAIL-PRESERVING CAP — the old build kept the FIRST 3000 chars of the thread (oldest replies),
 *     which cut off the resolution (usually the LAST reply) and drove 253/420 harvest kills as
 *     "not substantive". Now: first 600 chars (context) + '…' + last 2400 chars (the fix).
 *  2. TOPIC-TARGETED COHORT — preprod has 4,097 reply-bearing cases but one harvest = one GPT-4o
 *     call and the job's MAX_DEPTH backstop caps a run at ~550 cases. Cases matching a seed-topic
 *     term (22 original seeds + 19 gap topics from docs/decline-labels-2026-07-22.csv) are taken
 *     first (newest first), then newest non-matching cases fill to the cap.
 *
 * Inputs (scratchpad exports, see plan): preprod_replies.json, preprod_cases.json, vscode_cases.json
 * Output: mining-import-2026-07-22.csv (ParentId,Incoming,Status,Subject,TextBody)
 *
 * Run:  node scripts/data/build_mining_import2.js <scratchpadDir> <outCsv>
 * Then: sf data import bulk --sobject EmailMessage --file <outCsv> -o vscodeOrg --wait 10
 * Rollback: scripts/apex/rollback_mining_import.apex with TAG='[MINING-IMPORT-2026-07-22]%'
 */
'use strict';
const fs = require('fs');
const path = require('path');

const CAP = 3000;            // mirrors CaseMiningJob.REPLY_CAP_PER_CASE
const HEAD_KEEP = 600;       // thread opening (what was asked / first diagnosis)
const COHORT_CAP = 550;      // ~MAX_DEPTH-safe harvest volume
const SUBJECT_TAG = '[MINING-IMPORT-2026-07-22] ';

// Seed-topic terms (lowercase substring match on subject + merged reply text).
const TOPIC_TERMS = [
  // original 22-seed backlog
  'invalid field id', 'sdtemplate__c sobject type', "sobject type 'sdoc__sdtemplate__c'",
  'sstemplateeditor', 'generatedocumentinvocable', 'ending position out of bounds',
  'invalid type: contentdistribution', 'contentdistribution', 'zqu_quote__c', 'zqu__quote__c',
  'invalid license key', 'license key is invalid', 'job splitter', 'multiple templates in one job',
  'upgrade from version 8', 'skip version upgrade', 'external client app', 'docx to pdf',
  'pdf looks different', 'jpeg image', 'usage per user', 'documents generated per user',
  'usage report', 'character limit in merge field', 'next signer email',
  'signer notification template', 'clickable link', 'logo position', 'logo placement',
  'sort order', 'table sorting', 'hubspot',
  // 2026-07-22 decline-label gap topics (docs/decline-labels-2026-07-22.csv)
  'accessibility', 'wcag', 'tagged pdf', 'dynamic job splitter', 'content library',
  'connected apps with oauth', 'offline signing', 'sign offline', 'tracking pixel',
  'pdf rendering service', 'blob.topdf', 'sans serif', 'sans-serif',
  'invalid for your session', 'live edit', 'external access', 'public read',
  'batchable instance is too big', 'notificationemailschedulable', 'regex too complicated',
  'signer profile', 'required_field_missing', 'version data', 'list of sobjects is empty',
  'mass merge', 'mail merge',
];

const scratch = process.argv[2];
const outCsv = process.argv[3] || path.join(scratch, 'mining-import-2026-07-22.csv');
const read = f => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8').replace(/^﻿/, ''));

const stripHtml = h => (h || '')
  .replace(/<style[\s\S]*?<\/style>/gi, ' ')
  .replace(/<[^>]+>/g, ' ')
  .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/[ \t]+/g, ' ').trim();

const csvCell = v => /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;

const replies = read('preprod_replies.json').result.records;
const preprodCases = read('preprod_cases.json').result.records;
const vscodeCases = read('vscode_cases.json').result.records;

const preprodIdToNum = new Map(preprodCases.map(c => [c.Id, c.CaseNumber]));
const vscodeNumToId = new Map(vscodeCases.map(c => [c.CaseNumber, c.Id]));

// Group replies per preprod case (export is CreatedDate ASC already).
const byCase = new Map();
for (const r of replies) {
  if (!byCase.has(r.ParentId)) byCase.set(r.ParentId, []);
  byCase.get(r.ParentId).push(r);
}

const candidates = [];
let skippedNoJoin = 0, skippedEmpty = 0;
for (const [preprodId, rs] of byCase) {
  const num = preprodIdToNum.get(preprodId);
  const vscodeId = num && vscodeNumToId.get(num);
  if (!vscodeId) { skippedNoJoin++; continue; }

  let merged = '';
  for (const r of rs) {
    const text = (r.TextBody && r.TextBody.trim()) ? r.TextBody.trim() : stripHtml(r.HtmlBody);
    if (!text) continue;
    merged = merged ? merged + '\n---\n' + text : text;
  }
  if (!merged) { skippedEmpty++; continue; }
  if (merged.length > CAP) {
    merged = merged.slice(0, HEAD_KEEP) + '\n…\n' + merged.slice(-(CAP - HEAD_KEEP - 3));
  }

  const hay = ((rs[0].Subject || '') + ' ' + merged).toLowerCase();
  candidates.push({
    vscodeId,
    subject: (SUBJECT_TAG + (rs[0].Subject || 'agent replies')).slice(0, 200),
    body: merged,
    topical: TOPIC_TERMS.some(t => hay.includes(t)),
    lastDate: String(rs[rs.length - 1].CreatedDate),
  });
}

candidates.sort((a, b) =>
  (b.topical - a.topical) || b.lastDate.localeCompare(a.lastDate));
const chosen = candidates.slice(0, COHORT_CAP);

// Bulk API v2 validates line endings against the org's CRLF setting — use CRLF everywhere,
// including inside quoted bodies.
const lines = ['ParentId,Incoming,Status,Subject,TextBody'];
for (const c of chosen) {
  const body = c.body.replace(/\r?\n/g, '\r\n');
  lines.push([c.vscodeId, 'false', '3', csvCell(c.subject), csvCell(body)].join(','));
}
fs.writeFileSync(outCsv, lines.join('\r\n') + '\r\n', 'utf8');

console.log(JSON.stringify({
  preprodReplyCases: byCase.size, joined: candidates.length, skippedNoJoin, skippedEmpty,
  topical: candidates.filter(c => c.topical).length,
  chosen: chosen.length, chosenTopical: chosen.filter(c => c.topical).length,
  out: outCsv,
}, null, 1));
