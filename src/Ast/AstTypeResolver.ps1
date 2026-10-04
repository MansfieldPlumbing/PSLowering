Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AstType {
    <#
    .SYNOPSIS
        Resolves an AST TypeName or string into a concrete CLR Type.
    #>
    param(
        [Parameter(Mandatory)]
        $TypeName
    )

    if ($TypeName -is [Type]) {
        return $TypeName
    }

    if ($TypeName -is [System.Management.Automation.Language.ITypeName]) {
        $reflectionType = $TypeName.GetReflectionType()
        if ($null -ne $reflectionType) {
            return $reflectionType
        }
        $nameString = $TypeName.FullName
    }
    elseif ($TypeName -is [string]) {
        $nameString = $TypeName
    }
    else {
        throw "Cannot resolve type from unexpected object of type '$($TypeName.GetType().FullName)'."
    }

    $trimmed = $nameString.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']') -and -not $trimmed.EndsWith('[]')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    }

    if ($trimmed.EndsWith('[]')) {
        $elemName = $trimmed.Substring(0, $trimmed.Length - 2).Trim()
        $elemType = Resolve-AstType $elemName
        return $elemType.MakeArrayType()
    }

    # Common primitive aliases
    switch ($trimmed.ToLowerInvariant()) {
        'void'    { return [void] }
        'int'     { return [int] }
        'int32'   { return [int] }
        'long'    { return [long] }
        'int64'   { return [long] }
        'short'   { return [short] }
        'int16'   { return [short] }
        'byte'    { return [byte] }
        'sbyte'   { return [sbyte] }
        'uint'    { return [uint] }
        'uint32'  { return [uint] }
        'ulong'   { return [ulong] }
        'uint64'  { return [ulong] }
        'ushort'  { return [ushort] }
        'uint16'  { return [ushort] }
        'float'   { return [single] }
        'single'  { return [single] }
        'double'  { return [double] }
        'bool'    { return [bool] }
        'boolean' { return [bool] }
        'char'    { return [char] }
        'string'  { return [string] }
        'object'  { return [object] }
    }

    $clrType = [Type]::GetType($nameString, $false, $true)
    if ($null -ne $clrType) {
        return $clrType
    }

    # Search loaded assemblies
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        $found = $asm.GetType($nameString, $false, $true)
        if ($null -ne $found) {
            return $found
        }
    }

    throw "Type '$nameString' could not be resolved to a loaded CLR Type."
}
