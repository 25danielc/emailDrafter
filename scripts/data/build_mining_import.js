#!/usr/bin/env node
/**
 * build_mining_import.js — build the vscodeOrg EmailMessage import that feeds CaseMiningJob from
 * preprod's real agent replies (preprod has the email corpus but none of the pipeline; vscodeOrg
 * has the pipeline but no emails — CaseNumber is the join key).
 *
 * Emits ONE synthetic merged EmailMessage row per case: that case's outbound replies ordered by
 * preprod CreatedDate ASC, TextBody (else tag-stripped HtmlBody), joined with '\n---\n', capped at
 * 3000 chars — byte-identical to what CaseMiningJob.outboundReplyText would have assembled from
 * the individual messages (CreatedDate is not settable on insert, so chronology is pre-merged).
 * Rows are tagged Subject='[MINING-IMPORT-2026-07-21] ...' for one-command rollback
 * (scripts/apex/rollback_mining_import.apex).
 *
 * Usage:
 *   node build_mining_import.js <preprod_cases.csv> <preprod_replies.json> <vscode_cases.csv> <out.csv>
 *
 * Inputs:
 *   preprod_cases.csv   sf data query CSV: Id, CaseNumber, ... (only the first two columns are read)
 *   preprod_replies.json sf data query JSON: EmailMessage Id, ParentId, Subject, TextBody, HtmlBody, CreatedDate
 *   vscode_cases.csv    sf data query CSV: Id, CaseNumber
 * Output:
 *   out.csv             Bulk-API-ready EmailMessage insert: ParentId, Incoming, Status, Subject, TextBody
 */
'use strict';
const fs = require('fs');

const REPLY_CAP_PER_CASE = 3000; // mirrors CaseMiningJob.REPLY_CAP_PER_CASE
const SUBJECT_TAG = '[MINING-IMPORT-2026-07-21] ';

// PowerShell's Out-File writes a UTF-8 BOM; strip it so JSON.parse / the row regex see clean text.
const read = (p) => fs.readFileSync(p, 'utf8').replace(/^﻿/, '');

function idCaseNumberMap(csvPath, keyFirst) {
  // Rows are "<18-char Id>,<CaseNumber>[,rest...]"; continuation lines of quoted multi-line cells
  // never start with a record Id, so they are skipped safely.
  const map = new Map();
  for (const line of read(csvPath).split(/\r?\n/)) {
    const m = line.match(/^"?(500[A-Za-z0-9]{15})"?,"?(\d{8})"?/);
    if (!m) continue;
    if (keyFirst) map.set(m[1], m[2]);      // preprod: Id -> CaseNumber
    else map.set(m[2], m[1]);               // vscode: CaseNumber -> Id
  }
  return map;
}

function stripHtml(html) {
  if (!html) return '';
  return html
    .replace(/<\s*(br|\/p|\/div|\/li|\/tr|\/h[1-6])[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/(\s*\n\s*){2,}/g, '\n\n')
    .trim();
}

function csvCell(s) {
  if (s == null) return '';
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

const [, , preprodCasesPath, repliesPath, vscodeCasesPath, outPath] = process.argv;
if (!outPath) {
  console.error('usage: node build_mining_import.js <preprod_cases.csv> <preprod_replies.json> <vscode_cases.csv> <out.csv>');
  process.exit(1);
}

const preprodIdToCaseNum = idCaseNumberMap(preprodCasesPath, true);
const vscodeCaseNumToId = idCaseNumberMap(vscodeCasesPath, false);
const records = JSON.parse(read(repliesPath)).result.records;

// Group replies by preprod case, keeping true chronology.
const byCase = new Map();
for (const r of records) {
  if (!byCase.has(r.ParentId)) byCase.set(r.ParentId, []);
  byCase.get(r.ParentId).push(r);
}

const lines = ['ParentId,Incoming,Status,Subject,TextBody'];
let matched = 0, skippedNoJoin = 0, skippedEmpty = 0, totalChars = 0;
for (const [preprodCaseId, replies] of byCase) {
  const caseNum = preprodIdToCaseNum.get(preprodCaseId);
  const vscodeId = caseNum && vscodeCaseNumToId.get(caseNum);
  if (!vscodeId) { skippedNoJoin++; continue; }

  replies.sort((a, b) => String(a.CreatedDate).localeCompare(String(b.CreatedDate)));
  let merged = '';
  for (const r of replies) {
    const text = (r.TextBody && r.TextBody.trim()) ? r.TextBody.trim() : stripHtml(r.HtmlBody);
    if (!text) continue;
    merged = merged ? merged + '\n---\n' + text : text;
    if (merged.length > REPLY_CAP_PER_CASE) { merged = merged.slice(0, REPLY_CAP_PER_CASE); break; }
  }
  if (!merged) { skippedEmpty++; continue; }

  const subject = (SUBJECT_TAG + (replies[0].Subject || 'agent replies')).slice(0, 200);
  lines.push([vscodeId, 'false', '3', csvCell(subject), csvCell(merged)].join(','));
  matched++;
  totalChars += merged.length;
}

fs.writeFileSync(outPath, lines.join('\n') + '\n', 'utf8');
console.log(`cases with replies: ${byCase.size}  imported rows: ${matched}  ` +
  `skipped (no vscodeOrg CaseNumber match): ${skippedNoJoin}  skipped (empty bodies): ${skippedEmpty}`);
console.log(`total body chars: ${totalChars} (~${Math.round(totalChars / 1024)} KB), ` +
  `avg ${matched ? Math.round(totalChars / matched) : 0} chars/case -> ${outPath}`);
