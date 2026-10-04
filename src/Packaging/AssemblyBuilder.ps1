Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeterministicMvid.ps1')

function New-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Creates a new PersistedAssemblyBuilder session.
    #>
    param(
        [Parameter(Mandatory)][string] $AssemblyName,
        [Parameter()][Reflection.Assembly] $CoreAssembly = [object].Assembly
    )

    $an = [Reflection.AssemblyName]::new($AssemblyName)
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($an, $CoreAssembly)
    $module = $builder.DefineDynamicModule("$AssemblyName.dll")

    [pscustomobject]@{
        AssemblyName = $AssemblyName
        Builder      = $builder
        Module       = $module
        Types        = [System.Collections.Generic.Dictionary[string, Reflection.Emit.TypeBuilder]]::new()
    }
}

function Save-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Saves the PersistedAssemblyBuilder session to the specified output path.
    .DESCRIPTION
        Creates types, serializes to a MemoryStream, applies deterministic MVID
        if requested, and writes atomically to disk using a temporary file.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject] $Session,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [switch] $Deterministic = $true
    )

    $fullOut = if ([IO.Path]::IsPathFullyQualified($OutputPath)) {
        [IO.Path]::GetFullPath($OutputPath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
    }

    $outDir = [IO.Path]::GetDirectoryName($fullOut)
    if ($outDir -and -not [IO.Directory]::Exists($outDir)) {
        [IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    # Ensure all defined types are created
    foreach ($tb in $Session.Types.Values) {
        if (-not $tb.IsCreated()) {
            $null = $tb.CreateType()
        }
    }

    $ms = [IO.MemoryStream]::new()
    try {
        $Session.Builder.Save($ms)
        $bytes = $ms.ToArray()
    }
    finally {
        $ms.Dispose()
    }

    if ($Deterministic) {
        $bytes = Set-DeterministicMvid -Assembly $bytes
    }

    # Atomic file write to avoid partial artifacts on failure
    $tempFile = [IO.Path]::Combine($outDir, [IO.Path]::GetRandomFileName() + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tempFile, $bytes)
        [IO.File]::Move($tempFile, $fullOut, $true)
    }
    finally {
        if ([IO.File]::Exists($tempFile)) {
            [IO.File]::Delete($tempFile)
        }
    }

    $sha256 = [Security.Cryptography.SHA256]::HashData($bytes)
    $hexHash = [BitConverter]::ToString($sha256).Replace('-', '')

    [pscustomobject]@{
        OutputPath   = $fullOut
        Length       = $bytes.Length
        SHA256       = $hexHash
        Deterministic = [bool]$Deterministic
    }
}
