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

        [switch] $Deterministic = $true,

        # A static method to mark as the entry point. The image is then an
        # executable rather than a library; without it the bytes are exactly
        # what PersistedAssemblyBuilder.Save writes.
        [Parameter()][Reflection.Emit.MethodBuilder] $EntryPoint
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

    if ($EntryPoint) {
        # PersistedAssemblyBuilder.Save always writes a library with no entry
        # point (WritePEImage, runtime ab194157). An executable is the same
        # metadata serialized by ManagedPEBuilder with an executable header
        # and the entry method's handle, which exists once metadata is built.
        $ilStream = $null
        $fieldData = $null
        $metadata = $Session.Builder.GenerateMetadata([ref]$ilStream, [ref]$fieldData)
        if ($EntryPoint.MetadataToken -eq 0) {
            throw "Entry point '$($EntryPoint.Name)' has no metadata token after metadata generation."
        }
        $entryHandle = [Reflection.Metadata.Ecma335.MetadataTokens]::MethodDefinitionHandle($EntryPoint.MetadataToken -band 0x00FFFFFF)
        $peBuilder = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
            [Reflection.PortableExecutable.PEHeaderBuilder]::CreateExecutableHeader(),
            [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
            $ilStream, $fieldData, $null, $null, $null, 0, $entryHandle)
        $peBlob = [Reflection.Metadata.BlobBuilder]::new()
        $null = $peBuilder.Serialize($peBlob)
        $bytes = $peBlob.ToArray()
    }
    else {
        $ms = [IO.MemoryStream]::new()
        try {
            $Session.Builder.Save($ms)
            $bytes = $ms.ToArray()
        }
        finally {
            $ms.Dispose()
        }
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

    # An executable runs on the shared framework it was compiled against: the
    # runtime configuration names that framework and its exact version.
    $runtimeConfigPath = $null
    if ($EntryPoint) {
        $runtimeVersion = ([object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute], $false)[0].InformationalVersion -split '\+')[0]
        $runtimeConfigPath = [IO.Path]::ChangeExtension($fullOut, '.runtimeconfig.json')
        $runtimeConfig = [ordered]@{
            runtimeOptions = [ordered]@{
                tfm       = "net$([Environment]::Version.Major).$([Environment]::Version.Minor)"
                framework = [ordered]@{ name = 'Microsoft.NETCore.App'; version = $runtimeVersion }
            }
        }
        [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 4))
    }

    $sha256 = [Security.Cryptography.SHA256]::HashData($bytes)
    $hexHash = [BitConverter]::ToString($sha256).Replace('-', '')

    [pscustomobject]@{
        OutputPath   = $fullOut
        Length       = $bytes.Length
        SHA256       = $hexHash
        Deterministic = [bool]$Deterministic
        EntryPoint    = if ($EntryPoint) { $EntryPoint.Name } else { $null }
        RuntimeConfig = $runtimeConfigPath
    }
}
