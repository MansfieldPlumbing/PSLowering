<#
.SYNOPSIS
    Compares fresh legacy builds and rejections with the immutable 218f54e manifest.
#>
param([string]$ManifestPath = (Join-Path $PSScriptRoot 'baseline/218f54e.json'), [switch]$SkipNegativeControl)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or [Environment]::Version.ToString() -cne '11.0.0') {
    throw 'Ratchet requires the pinned PowerShell and runtime.'
}
if ([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription -cne '.NET 11.0.0-rc.1.26425.128') { throw 'Ratchet runtime pin mismatch.' }
$root=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $root 'Export-LoweredAssembly.ps1'
. (Join-Path $PSScriptRoot 'LegacyMetadata.ps1')
$manifest=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.BaselineCommit -cne '218f54e60e7750dc28576dfdb51cebbadad7fa9f' -or $manifest.Outputs.Count -ne 52 -or $manifest.Diagnostics.Count -ne 14) { throw 'Frozen baseline identity or count mismatch.' }
$dir=Join-Path $root 'build/legacy-ratchet'
$null=New-Item -ItemType Directory -Force $dir

function Compare-LegacyEvidence($Expected,$ObservedEvidence) {
    $errors=[Collections.Generic.List[string]]::new()
    foreach($p in $Expected.Outputs) {
        $r=$ObservedEvidence.Outputs | Where-Object Path -CEQ $p.Path
        if (@($r).Count -ne 1 -or $r.SHA256 -cne $p.SHA256 -or $r.MVID -cne $p.MVID -or
            (ConvertTo-Json -InputObject $r.References -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $p.References -Depth 5 -Compress)) { $errors.Add("Output drift: $($p.Path)") }
    }
    foreach($p in $Expected.Diagnostics) {
        $r=$ObservedEvidence.Diagnostics | Where-Object Case -CEQ $p.Case
        if (@($r).Count -ne 1 -or $r.Message -cne $p.Message) { $errors.Add("Diagnostic drift: $($p.Case)") }
    }
    if ($errors.Count) { throw ($errors -join "`n") }
}

$outputs=@(foreach($p in $manifest.Outputs) {
    # Every path is rebuilt, including historical oracle/repro aliases. Never
    # consume a cached DLL left by a previous suite or a previous local run.
    $path=Join-Path $dir $p.Path
    $compileArguments=@{SourcePath=(Join-Path $root $p.Fixture);ClassName=$p.ClassName;OutputPath=$path;Deterministic=$true}
    if ($p.EntryPoint) { $compileArguments.EntryPoint=$p.EntryPoint }
    $null=& $compiler @compileArguments
    $r=Read-LegacyAssembly $path
    [pscustomobject]@{Path=$p.Path;SHA256=$r.SHA256;MVID=$r.MVID;References=$r.References}
})
$diagnostics=@(foreach($p in $manifest.Diagnostics) {
    $source=Join-Path $dir ($p.Case+'.ps1')
    $output=Join-Path $dir ($p.Case+'.dll')
    [IO.File]::WriteAllText($source,$p.Source)
    if(Test-Path $output) { Remove-Item -LiteralPath $output }
    $message=$null
    try { $null=& $compiler -SourcePath $source -ClassName $p.Case -OutputPath $output } catch { $message=$_.Exception.Message }
    if($null -eq $message -or (Test-Path $output)) { throw "Legacy rejection admitted or wrote output: $($p.Case)" }
    [pscustomobject]@{Case=$p.Case;Message=$message.Replace("`r`n","`n")}
})
$actualEvidence=[pscustomobject]@{Outputs=$outputs;Diagnostics=$diagnostics}
$actualEvidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'actual.json')
Compare-LegacyEvidence $manifest $actualEvidence
if(-not $SkipNegativeControl) {
    # Exercise the same comparator on independently altered expected evidence.
    # Copies stay under ignored build/; the checked-in manifest is never written.
    foreach($kind in 'artifact','diagnostic') {
        $bad=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        if($kind -eq 'artifact') { $bad.Outputs[0].SHA256='0'*64 }
        else { $bad.Diagnostics[0].Message+=' intentionally modified expected diagnostic' }
        $rejected=$false
        try { Compare-LegacyEvidence $bad $actualEvidence } catch { $rejected=$_.Exception.Message -match 'drift:' }
        if(-not $rejected) { throw "Ratchet negative control failed: $kind" }
        $badPath=Join-Path $dir "negative-$kind.json"
        $bad | ConvertTo-Json -Depth 10 | Set-Content $badPath
        & ([Environment]::ProcessPath) -NoProfile -File $PSCommandPath -ManifestPath $badPath -SkipNegativeControl *> (Join-Path $dir "negative-$kind.log")
        if($LASTEXITCODE -eq 0) { throw "Executable ratchet accepted altered expectation: $kind" }
    }
}
[pscustomobject]@{Outputs=52;Diagnostics=14;Regressions=0;NegativeControls=2;Status='PASS'} | ConvertTo-Json | Set-Content (Join-Path $dir 'receipt.json')
Write-Host 'Legacy ratchet: 52 outputs, 14 diagnostics, 0 regressions; negative controls passed.'
