function Get-ChildPwshCommand {
    <#
    .SYNOPSIS
        The command line that starts another instance of the running pwsh.
    .DESCRIPTION
        Returns the executable followed by any arguments it needs. When
        PowerShell runs as a .NET tool (dotnet tool run pwsh), the process is
        the dotnet host, so the command is dotnet followed by pwsh.dll from
        $PSHOME.
    #>
    $exe = [Environment]::ProcessPath
    if ([IO.Path]::GetFileNameWithoutExtension($exe) -eq 'dotnet') {
        return , [string[]]@($exe, (Join-Path $PSHOME 'pwsh.dll'))
    }
    , [string[]]@($exe)
}
