param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $root 'Export-LoweredAssembly.ps1'
$files=@(& git -C $root ls-files --cached --others --exclude-standard)
if($LASTEXITCODE) { throw 'Architecture inventory failed.' }
foreach($file in $files) {
    if($file -match '^(src|modules)/' -or $file -match '\.(psm1|psd1|dll|cs|fs|vb)$') { throw "Additional compiler implementation surface: $file" }
    if($file -match '\.ps1$' -and $file -cne 'Export-LoweredAssembly.ps1' -and
        $file -cne 'tools/Get-PowerShell.ps1' -and $file -notmatch '^(tests|probes|experiments)/') { throw "Additional implementation script: $file" }
}
$ast=[Management.Automation.Language.Parser]::ParseFile($compiler,[ref]$null,[ref]$null)
$loaders=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and
    ($n.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -or $n.GetCommandName() -in 'Import-Module','Invoke-Expression','Add-Type')},$true))
if($loaders.Count) { throw 'Compiler contains an external implementation loader.' }
$dir=Join-Path ([IO.Path]::GetTempPath()) ('PSLowering-Isolated-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $dir
try {
    Copy-Item -LiteralPath $compiler -Destination "$dir/Export-LoweredAssembly.ps1"
    Copy-Item -LiteralPath "$root/tests/fixtures/Slice1Fixture.ps1" -Destination "$dir/input.ps1"
    Copy-Item -LiteralPath "$root/tests/native-fixtures/NativeInteropFixture.ps1" -Destination "$dir/native.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SingleFileProbe.ps1') -Destination "$dir/Probe.ps1"
    $info=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach($arg in @('-NoProfile','-File',"$dir/Probe.ps1")) { $info.ArgumentList.Add($arg) }
    $info.WorkingDirectory=$dir
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if($process.ExitCode) { throw ('Isolated compiler failed: '+$stdout.Result+$stderr.Result) }
}
finally {
    # The only removal target is the exact directory created above.
    if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
Write-Host 'Single-file architecture: isolated compile, expression, inspect, capability and help passed.'
