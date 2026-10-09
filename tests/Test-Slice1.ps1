[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice1Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice1'
$outDll = Join-Path $outDir 'Slice1Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice1Fixture..."
$exportReceipt = & $compilerPath -Mode Compile `
    -SourcePath $fixturePath `
    -ClassName 'Slice1Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = & $compilerPath -Mode Inspect -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 1 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice1Fixture', $true)

$ans = $type.GetMethod('GetAnswer').Invoke($null, @())
if ($ans -ne 42) { throw "GetAnswer returned '$ans', expected 42" }

$fls = $type.GetMethod('GetFalse').Invoke($null, @())
if ($fls -ne $false) { throw "GetFalse returned '$fls', expected false" }

$str = $type.GetMethod('GetGreeting').Invoke($null, @())
if ($str -ne 'hello') { throw "GetGreeting returned '$str', expected 'hello'" }

$nullRet = $type.GetMethod('DoNothing').Invoke($null, @())
if ($null -ne $nullRet) { throw "DoNothing returned a value, expected null" }

$inst = [Activator]::CreateInstance($type)
$instVal = $type.GetMethod('GetInstanceVal').Invoke($inst, @())
if ($instVal -ne 100) { throw "GetInstanceVal returned '$instVal', expected 100" }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$freshScript = @"
`$ErrorActionPreference = 'Stop'
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$type = `$asm.GetType('Slice1Fixture', `$true)
if (`$type.GetMethod('GetAnswer').Invoke(`$null, @()) -ne 42) { exit 1 }
if (`$type.GetMethod('GetFalse').Invoke(`$null, @()) -ne `$false) { exit 2 }
if (`$type.GetMethod('GetGreeting').Invoke(`$null, @()) -ne 'hello') { exit 3 }
`$inst = [Activator]::CreateInstance(`$type)
if (`$type.GetMethod('GetInstanceVal').Invoke(`$inst, @()) -ne 100) { exit 4 }
Write-Output 'FRESH_PROCESS_SLICE1=PASS'
"@

$freshScriptPath = Join-Path $outDir 'invoke_fresh.ps1'
[IO.File]::WriteAllText($freshScriptPath, $freshScript)

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
& $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoLogo -NoProfile -File $freshScriptPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Fresh-process invocation failed with exit code $LASTEXITCODE"
}

# 3. Determinism check
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice1_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice1Fixture.dll'
$null = & $compilerPath -Mode Compile -SourcePath $fixturePath -ClassName 'Slice1Fixture' -OutputPath $outDll2 -Deterministic
$t2 = & $compilerPath -Mode Inspect -AssemblyPath $outDll2

if ($t2.SHA256 -ne $testReceipt.SHA256 -or $t2.MVID -ne $testReceipt.MVID) {
    throw "Determinism check failed: hashes differ ($($testReceipt.SHA256) vs $($t2.SHA256))"
}


# Single-file execution contract, including a copied script with no components.
$parseErrors = $null
$compilerAst = [System.Management.Automation.Language.Parser]::ParseFile($compilerPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Compiler does not parse as one PowerShell AST.' }
$loaders = @($compilerAst.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and
    ($n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -or
     $n.GetCommandName() -in 'Import-Module', 'Export-ModuleMember')
}, $true))
if ($loaders.Count) { throw 'Compiler requires an external implementation loader.' }
$isolatedDir = Join-Path $repoRoot 'build/single-script'
$null = New-Item -ItemType Directory -Force -Path $isolatedDir
$isolatedCompiler = Join-Path $isolatedDir 'Export-LoweredAssembly.ps1'
Copy-Item -LiteralPath $compilerPath -Destination $isolatedCompiler -Force
Push-Location ([IO.Path]::GetTempPath())
try {
    $isolated = & $isolatedCompiler -SourcePath $fixturePath -ClassName Slice1Fixture -OutputPath (Join-Path $isolatedDir 'Slice1Fixture.dll') -Deterministic
    $isolatedReport = & $isolatedCompiler -Mode Inspect -AssemblyPath $isolated.OutputPath
    if ($isolatedReport.SHA256 -ne $testReceipt.SHA256 -or $isolatedReport.MVID -ne $testReceipt.MVID) {
        throw 'Isolated direct invocation changed deterministic assembly output.'
    }
    $capability = & $isolatedCompiler -Mode Capability
    if ($capability.Product -ne 'Dev.MansfieldPlumbing.PowerShell.Lowering' -or -not $capability.PersistedAssemblyBuilder) {
        throw 'Capability object contract changed.'
    }
    $helpText = & $isolatedCompiler -Help | Out-String
    if ($helpText -notmatch 'MethodAst' -or $helpText -notmatch 'Capability') { throw 'Script help is incomplete.' }
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseFile($fixturePath, [ref]$null, [ref]$null)
    $method = $fixtureAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionMemberAst] -and $n.Name -eq 'GetAnswer' }, $true)
    $expression = $method | & $isolatedCompiler -Mode Expression
    if ($expression.Lambda -isnot [Linq.Expressions.LambdaExpression] -or $expression.Lambda.Compile().DynamicInvoke() -ne 42) {
        throw 'Expression mode did not return a live executable expression in process.'
    }
}
finally { Pop-Location }

[pscustomobject]@{
    Slice              = 1
    Status             = 'PASS'
    Assembly           = $outDll
    Length             = $testReceipt.Length
    SHA256             = $testReceipt.SHA256
    MVID               = $testReceipt.MVID
    SmaReferenced      = $testReceipt.SmaReferenced
    ClrOnlyAdmitted    = $testReceipt.ClrOnlyAdmitted
    FreshProcessResult = 'PASS'
    DeterminismMatch   = 'PASS'
}
