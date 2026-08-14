# run_gap_probe.ps1 — drive scripts/apex/probe_gap_docs.apex over all 19 corpus-gap cases
# (5 chunks of <=4, SOSL budget), merge the chunk JSONs, and print the per-slug pass/fail table.
# Run AFTER a help.sdocs re-sync + embedding backfill to measure whether newly authored gap docs
# retrieve above the 0.45 draft floor for the cases that exposed each gap.
#
# Usage:  powershell -File scripts\run_gap_probe.ps1 [-Label gap-probe-2026-07-24] [-TargetOrg vscodeOrg]
param(
    [string]$Label = ("gap-probe-" + (Get-Date -Format "yyyy-MM-dd-HHmm")),
    [string]$TargetOrg = "vscodeOrg"
)
$ErrorActionPreference = "Stop"
$template = Get-Content "scripts\apex\probe_gap_docs.apex" -Raw

foreach ($start in 0, 2, 4, 6, 8, 10, 12, 14, 16, 18) {
    $body = $template.Replace("__RUN_LABEL__", $Label).Replace("__START__", "$start")
    $tmp = Join-Path $env:TEMP "probe_gap_docs_$start.apex"
    # BOM-less UTF-8: PS 5.1's Out-File utf8 writes a BOM the Apex compiler rejects.
    [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "chunk $start..."
    sf apex run -o $TargetOrg -f $tmp | Out-Null
    if (-not $?) { Write-Host "chunk $start FAILED" }
}

# Merge chunk outputs.
$q = "SELECT Id, Title FROM ContentVersion WHERE Title LIKE 'Gap Probe $Label-c%' ORDER BY Title"
$res = sf data query -o $TargetOrg -q $q --json | ConvertFrom-Json
$allRows = @()
foreach ($rec in $res.result.records) {
    $json = sf api request rest "/services/data/v61.0/sobjects/ContentVersion/$($rec.Id)/VersionData" -o $TargetOrg
    $obj = $json | ConvertFrom-Json
    $allRows += $obj.rows
}

$out = @()
foreach ($r in $allRows) {
    $top1 = if ($r.top3 -and $r.top3.Count -gt 0) { $r.top3[0].name } else { "" }
    $out += [pscustomobject]@{
        slug = $r.slug; caseNumber = $r.caseNumber
        topScore = if ($null -ne $r.topScore) { [math]::Round($r.topScore, 3) } else { $null }
        passesFloor = $r.passesFloor; top1Doc = $top1; error = $r.error
    }
}
$out | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$csvPath = "docs\$Label.csv"
$out | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
$pass = ($out | Where-Object { $_.passesFloor -eq $true }).Count
Write-Host "PASS $pass / $($out.Count) slugs above the 0.45 floor. Saved $csvPath"
