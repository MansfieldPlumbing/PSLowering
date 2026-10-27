param([Parameter(Mandatory)][string] $SourceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or [object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion -notlike '11.0.0-rc.1.26425.128*') { throw 'Use the pinned verification toolchain.' }
if(-not $IsWindows -or [IntPtr]::Size -ne 8) { throw 'This consumer probe requires Windows x64.' }
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work=Join-Path $root 'build/consumer-native/windows'
$null=New-Item -ItemType Directory -Force $work
$identities=Get-Content (Join-Path $root 'docs/native-reference-identities.json') -Raw | ConvertFrom-Json
foreach($relative in @('src/Native.ps1','src/managed/MediaSessionEvents.ps1','src/managed/AudioCapture.ps1')) {
    $expected=$identities | Where-Object { $_.Repository -eq 'QuickPS' -and $_.Path -eq $relative }
    if((Get-FileHash (Join-Path $SourceRoot "QuickPS/$relative")).Hash -cne $expected.SHA256) { throw 'Consumer input digest mismatch.' }
}
$compiler=Join-Path $root 'Export-LoweredAssembly.ps1'
$admission=@(foreach($name in @('MediaSessionEvents','AudioCapture')) {
    $target=Join-Path $work "$name.dll"
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $result=& $compiler -SourcePath (Join-Path $SourceRoot "QuickPS/src/managed/$name.ps1") -OutputPath $target
        [pscustomobject]@{Source=$name;Admitted=$true;Milliseconds=$timer.Elapsed.TotalMilliseconds;Diagnostic=$null;Methods=$result.EmittedMethods.Count}
    } catch {
        [pscustomobject]@{Source=$name;Admitted=$false;Milliseconds=$timer.Elapsed.TotalMilliseconds;Diagnostic=$_.Exception.Message;ArtifactWritten=(Test-Path $target)}
    }
})
$dll=Join-Path $work 'QuickPSComFixture.dll'
$timer=[Diagnostics.Stopwatch]::StartNew()
$null=& $compiler -SourcePath (Join-Path $PSScriptRoot 'QuickPSComFixture.ps1') -OutputPath $dll -EntryPoint Main
$compileMs=$timer.Elapsed.TotalMilliseconds
& (Join-Path $PSScriptRoot 'Assert-ConsumerMetadata.ps1') -AssemblyPath $dll -Consumer QuickPS
$type=[Reflection.Assembly]::LoadFile($dll).GetType('QuickPSComFixture',$true)
$native=& (Join-Path $SourceRoot 'QuickPS/src/Native.ps1')
# The original typed class body is extracted unchanged, excluding its top-level
# invocation guard. Its Call method is the SMA oracle, not the adapter stub.
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'QuickPS/src/managed/MediaSessionEvents.ps1'),[ref]$tokens,[ref]$parseErrors)
$class=$ast.Find({param($node) $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'QuickPSMediaSessionEvents'},$true)
$oraclePath=Join-Path $work 'QuickPSMediaSessionEvents.oracle.ps1'
[IO.File]::WriteAllText($oraclePath,$class.Extent.Text)
. $oraclePath
$worker=New-Object QuickPSMediaSessionEvents
$scratch=[Runtime.InteropServices.Marshal]::AllocHGlobal(40)
$event=[IntPtr]::Zero
$session=[IntPtr]::Zero
$comparisons=0
$comInitialized=$false; $mfStarted=$false
function Ensure($condition,[string]$message) { if(-not $condition) { throw $message } }
try {
    $apartment=[Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    $coFlags=[uint]$(if($apartment -eq 'STA'){2}else{0})
    $coResult=$type.GetMethod('InitializeCom').Invoke($null,@([IntPtr]::Zero,$coFlags))
    Ensure ($coResult -ge 0) "CoInitializeEx failed with HRESULT $coResult."
    $comInitialized=$true
    Ensure ($type.GetMethod('Startup').Invoke($null,@([uint]131184,[uint]0)) -ge 0) 'MFStartup failed.'
    $mfStarted=$true
    for($index=0;$index -lt 40;$index++){[Runtime.InteropServices.Marshal]::WriteByte($scratch,$index,0)}
    Ensure ($type.GetMethod('CreateSession').Invoke($null,@([IntPtr]::Zero,[IntPtr]::Add($scratch,24))) -eq 0) 'MFCreateMediaSession failed.'
    $session=[Runtime.InteropServices.Marshal]::ReadIntPtr($scratch,24)
    $sessionTable=[Runtime.InteropServices.Marshal]::ReadIntPtr($session)
    $getPointer=[Runtime.InteropServices.Marshal]::ReadIntPtr($sessionTable,3 * [IntPtr]::Size)
    $queuePointer=[Runtime.InteropServices.Marshal]::ReadIntPtr($sessionTable,6 * [IntPtr]::Size)
    $sessionOracle=$native.GetComCall($session,3,[int],[Type[]]@([uint],[IntPtr]))
    $worker.Signatures=[Type[]]@($sessionOracle.GetType())
    # Flags 1 is MF_EVENT_FLAG_NO_WAIT: empty-queue negative result must agree.
    $expectedHr=$worker.Call($session,3,0,[object[]]@($session,[uint]1,$scratch))
    $observedHr=$type.GetMethod('GetEvent').Invoke($null,@($getPointer,$session,[uint]1,$scratch))
    Ensure ($expectedHr -lt 0 -and [object]::Equals($expectedHr,$observedHr)) 'Empty event queue parity failed.'
    $comparisons++
    # Two identical events avoid comparing different queue states. The second
    # uses flags 0, the exact blocking call shape in QuickPS's worker.
    foreach($side in @('PowerShell','Lowered')) {
        for($index=0;$index -lt 16;$index++){[Runtime.InteropServices.Marshal]::WriteByte($scratch,$index,0)}
        Ensure ($type.GetMethod('QueueEvent').Invoke($null,@($queuePointer,$session,111,$scratch,-2147467259,[IntPtr]::Zero)) -eq 0) 'QueueEvent failed.'
        $getHr=if($side -eq 'PowerShell'){$worker.Call($session,3,0,[object[]]@($session,[uint]0,$scratch))}else{$type.GetMethod('GetEvent').Invoke($null,@($getPointer,$session,[uint]0,$scratch))}
        Ensure ($getHr -eq 0) 'GetEvent failed after QueueEvent.'
        $event=[Runtime.InteropServices.Marshal]::ReadIntPtr($scratch)
        foreach($slot in @(33,35)) {
            Ensure ($type.GetMethod('ReadEvent').Invoke($null,@($event,$slot,$scratch)) -eq 0) 'Queued event getter failed.'
            $value=[Runtime.InteropServices.Marshal]::ReadInt32($scratch)
            Ensure ($value -eq $(if($slot -eq 33){111}else{-2147467259})) 'Queued event value mismatch.'
        }
        $null=[Runtime.InteropServices.Marshal]::Release($event);$event=[IntPtr]::Zero
    }
    $comparisons++
    for($index=0;$index -lt 16;$index++){[Runtime.InteropServices.Marshal]::WriteByte($scratch,$index,0)}
    $vectors=@(@(111,-2147467259),@(106,0),@(0,1),@(111,[int]::MinValue),@(106,[int]::MaxValue))
    foreach($vector in $vectors) {
        $hr=$type.GetMethod('CreateEvent').Invoke($null,@([int]$vector[0],$scratch,[int]$vector[1],[IntPtr]::Zero,[IntPtr]::Add($scratch,24)))
        Ensure ($hr -eq 0) 'MFCreateMediaEvent failed.'
        $event=[Runtime.InteropServices.Marshal]::ReadIntPtr($scratch,24)
        $call=$native.GetComCall($event,33,[int],[Type[]]@([IntPtr]))
        $worker.Signatures=[Type[]]@($call.GetType())
        foreach($item in @(@(33,$vector[0]),@(35,$vector[1]))) {
            $sourceHr=$worker.Call($event,$item[0],0,[object[]]@($event,$scratch))
            $sourceValue=[Runtime.InteropServices.Marshal]::ReadInt32($scratch)
            [Runtime.InteropServices.Marshal]::WriteInt32($scratch,1234)
            $loweredHr=$type.GetMethod('ReadEvent').Invoke($null,@($event,[int]$item[0],$scratch))
            $loweredValue=[Runtime.InteropServices.Marshal]::ReadInt32($scratch)
            Ensure ([object]::Equals($sourceHr,$loweredHr) -and [object]::Equals($sourceValue,$loweredValue) -and $loweredValue -eq $item[1]) 'COM HRESULT/out-value/type parity failed.'
            $comparisons++
        }
        $null=[Runtime.InteropServices.Marshal]::Release($event); $event=[IntPtr]::Zero
    }
    # Same real object, same slot, same output buffer; reflection invocation on
    # both measured paths includes host overhead. Warmup precedes each sample.
    $null=$type.GetMethod('CreateEvent').Invoke($null,@(111,$scratch,0,[IntPtr]::Zero,[IntPtr]::Add($scratch,24)))
    $event=[Runtime.InteropServices.Marshal]::ReadIntPtr($scratch,24)
    $worker.Signatures=[Type[]]@($native.GetComCall($event,33,[int],[Type[]]@([IntPtr])).GetType())
    $method=$type.GetMethod('ReadEvent'); $original=$worker.GetType().GetMethod('Call')
    $compiledArguments=[object[]]@($event,33,$scratch)
    $originalArguments=[object[]]@($event,33,0,[object[]]@($event,$scratch))
    $timings=@(foreach($side in @('PowerShell','Lowered')) {
        $target=if($side -eq 'PowerShell'){$worker}else{$null}
        $selected=if($side -eq 'PowerShell'){$original}else{$method}
        $parameters=if($side -eq 'PowerShell'){$originalArguments}else{$compiledArguments}
        for($i=0;$i -lt 100;$i++){ $null=$selected.Invoke($target,$parameters) }
        foreach($sample in 1..5) {
            $timer.Restart()
            for($i=0;$i -lt 1000;$i++){ $null=$selected.Invoke($target,$parameters) }
            [pscustomobject]@{Side=$side;Sample=$sample;Iterations=1000;Milliseconds=$timer.Elapsed.TotalMilliseconds}
        }
    })
} finally {
    if($event -ne [IntPtr]::Zero) { $null=[Runtime.InteropServices.Marshal]::Release($event) }
    if($session -ne [IntPtr]::Zero) {
        $shutdownPointer=[Runtime.InteropServices.Marshal]::ReadIntPtr([Runtime.InteropServices.Marshal]::ReadIntPtr($session),13 * [IntPtr]::Size)
        $null=$type.GetMethod('SessionShutdown').Invoke($null,@($shutdownPointer,$session))
        $null=[Runtime.InteropServices.Marshal]::Release($session)
    }
    [Runtime.InteropServices.Marshal]::FreeHGlobal($scratch)
    if($mfStarted){$null=$type.GetMethod('Shutdown').Invoke($null,@())}
    if($comInitialized){$null=$type.GetMethod('UninitializeCom').Invoke($null,@())}
    foreach($handle in $native.Libraries.Values){[Runtime.InteropServices.NativeLibrary]::Free($handle)}
}
& dotnet $dll
Ensure ($LASTEXITCODE -eq 0) 'Fresh zero-SMA COM host failed.'
$receipt=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();SMA=[Management.Automation.PowerShell].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion;CoreLib=[object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion;ComApartment=$apartment;CoInitializeResult=$coResult;CompileMilliseconds=$compileMs;ParityComparisons=$comparisons;ZeroSmaHost=$true;Admission=$admission;Timings=$timings;AssemblySHA256=(Get-FileHash $dll).Hash}
$receipt | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $work 'receipt.json')
Write-Host "QuickPS COM: $comparisons HRESULT/out-value comparisons passed; zero-SMA host passed."
