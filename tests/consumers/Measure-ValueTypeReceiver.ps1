# A bounded defect probe, not a passing regression gate. Exit 1 means the
# documented admitted-method divergence is still present; do not bless it.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or [object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion -notlike '11.0.0-rc.1.26425.128*'){throw 'Use the pinned verification toolchain.'}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work=Join-Path $root 'build/consumer-native/blockers'
$null=New-Item -ItemType Directory -Force $work
$source=Join-Path $PSScriptRoot 'ValueTypeReceiverFixture.ps1'
$tokens=$null; $issues=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$issues)
$call=$ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)
$dll=Join-Path $work 'ValueTypeReceiverFixture.dll'
$null=& (Join-Path $root 'Export-LoweredAssembly.ps1') -SourcePath $source -OutputPath $dll
$compiled=[Reflection.Assembly]::LoadFile($dll).GetType('ValueTypeReceiverFixture',$true)
. $source
$oracle='ValueTypeReceiverFixture' -as [Type]
$expected=$oracle.GetMethod('Format').Invoke($null,@([int]0))
$observed=$null; $failure=$null
try { $observed=$compiled.GetMethod('Format').Invoke($null,@([int]0)) }
catch {
    $exception=$_.Exception
    while($exception.InnerException){$exception=$exception.InnerException}
    $failure=$exception.GetType().FullName
}
$diverged=$failure -or -not [object]::Equals($expected,$observed)
[ordered]@{Fixture='ValueTypeReceiverFixture.ps1';Line=$call.Extent.StartLineNumber;Column=$call.Extent.StartColumnNumber;Input=0;Admitted=$true;Expected=$expected;Observed=$observed;RuntimeException=$failure;Diverged=[bool]$diverged;PowerShell=$PSVersionTable.PSVersion.ToString();CoreLib=[object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion} | ConvertTo-Json | Set-Content (Join-Path $work 'value-type-receiver.json')
if($diverged){Write-Host "consumer blocker: Format(0) expected '$expected'; lowered exception $failure";exit 1}
Write-Host 'Value-type receiver probe agrees; reassess the documented blocker.'
