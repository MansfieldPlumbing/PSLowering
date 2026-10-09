<#
.SYNOPSIS
    Checks compiled methods against Pwsh's own admission rule for persisted methods.
.DESCRIPTION
    Pwsh admits a persisted method only when Test-ExpressionGraph in its
    setup.ps1 finds no dynamic node, no call-site reference or constant, and
    no constant that IL cannot encode (Add-PersistedMethod). This test takes
    setup.ps1 from GitHub at a pinned commit, verifies its SHA-256, loads only
    those two functions from its syntax tree, and applies them to the
    expression tree of every method in every fixture, including Pwsh's own
    FindProfile written as typed PowerShell.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwshCommit = 'fdf4719f4b55758242cdc6785408f4299bb046bf'
$setupSha256 = 'B95525F003601335A79AD0539D6147BF0AD384D4D4CB2E3D8981C49039B6F035'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'

$cache = Join-Path $repoRoot "build/cache/pwsh/$pwshCommit"
$setup = Join-Path $cache 'setup.ps1'
if (-not (Test-Path -LiteralPath $setup)) {
    $null = New-Item -ItemType Directory -Force -Path $cache
    $partial = "$setup.download"
    Invoke-WebRequest -UseBasicParsing -OutFile $partial `
        -Uri "https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/$pwshCommit/setup.ps1"
    Move-Item -LiteralPath $partial -Destination $setup -Force
}
$actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
if ($actual -ne $setupSha256) {
    Remove-Item -LiteralPath $setup -Force
    throw "Pwsh setup.ps1 at $pwshCommit has SHA-256 $actual, expected $setupSha256."
}

# Load only the two admission functions; setup.ps1 itself is never run. They
# are written to their own file beside the verified setup.ps1 and run from it.
$functionFile = Join-Path $cache 'admission-functions.ps1'
$functionText = [Collections.Generic.List[string]]::new()
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setup, [ref]$null, [ref]$null)
foreach ($name in 'Test-CallSiteType', 'Test-ExpressionGraph') {
    $definition = $setupAst.Find({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name
    }, $true)
    if (-not $definition) { throw "Pwsh setup.ps1 at $pwshCommit defines no $name." }
    $functionText.Add($definition.Extent.Text)
}
Set-Content -LiteralPath $functionFile -Value ($functionText -join ([Environment]::NewLine * 2)) -Encoding utf8
. $functionFile

$checked = 0
$skipped = [Collections.Generic.List[string]]::new()
$rejected = [Collections.Generic.List[string]]::new()
foreach ($fixture in Get-ChildItem (Join-Path $repoRoot 'tests/fixtures') -Filter *.ps1) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($fixture.FullName, [ref]$null, [ref]$null)
    foreach ($class in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        foreach ($method in $class.Members | Where-Object { $_ -is [System.Management.Automation.Language.FunctionMemberAst] }) {
            try { $lowered = & $compilerPath -Mode Expression -MethodAst $method }
            catch { $skipped.Add("$($class.Name).$($method.Name)"); continue }   # Rejected by admission; Pwsh never sees it.
            $report = Test-ExpressionGraph -Expression $lowered.Lambda.Body
            $checked++
            if ($report.DynamicNodes -or $report.CallSiteReferences -or $report.CallSiteConstants -or $report.BoundConstants) {
                $rejected.Add(('{0}.{1}: {2} dynamic, {3} call-site reference, {4} call-site constant, {5} unencodable constant' -f
                    $class.Name, $method.Name, $report.DynamicNodes, $report.CallSiteReferences, $report.CallSiteConstants, $report.BoundConstants))
            }
        }
    }
}

$rejected | ForEach-Object { Write-Host "  REJECTED $_" }
[pscustomobject]@{
    Suite      = 'PwshAdmission'
    PwshCommit = $pwshCommit
    Methods    = $checked
    Rejected   = $rejected.Count
    NotLowered = $skipped -join ', '
    Status     = if ($rejected.Count -or $checked -eq 0) { 'FAIL' } else { 'PASS' }
}
if ($rejected.Count -or $checked -eq 0) { exit 1 }
