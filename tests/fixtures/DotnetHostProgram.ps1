class DotnetHostProgram {
    # Run by the dotnet host alone. Exit code 3 means a PowerShell engine
    # assembly is loaded in this process; otherwise the exit code is the
    # zero-based voice row for the phoneme count given as the first argument.
    static [int] Main([string[]] $arguments) {
        [System.Reflection.Assembly[]] $loaded = [System.AppDomain]::CurrentDomain.GetAssemblies()
        for ([int] $i = 0; $i -lt $loaded.Length; $i++) {
            [string] $name = $loaded[$i].GetName().Name
            if ($name.StartsWith('System.Management.Automation', [System.StringComparison]::Ordinal)) {
                return 3
            }
        }
        [int] $count = [int]::Parse($arguments[0])
        if ($count -lt 1 -or $count -gt 510) {
            throw [System.ArgumentOutOfRangeException]::new('count')
        }
        [int] $row = $count - 1
        [System.Console]::WriteLine([string]::Concat('row ', [System.Convert]::ToString($row)))
        return $row
    }
}
