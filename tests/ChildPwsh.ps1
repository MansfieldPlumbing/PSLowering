function Get-ChildPwshCommand {
    <#
    .SYNOPSIS
        The command line that starts another instance of the running pwsh.
    #>
    , [string[]]@([Environment]::ProcessPath)
}
