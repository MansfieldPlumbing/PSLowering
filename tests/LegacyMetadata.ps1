# Independent metadata reader for the frozen historical ratchet.
function Read-LegacyAssembly([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $pe=[Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader=[Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $refs=@(foreach($handle in $reader.AssemblyReferences) {
            $ref=$reader.GetAssemblyReference($handle)
            [ordered]@{Name=$reader.GetString($ref.Name);Version=$ref.Version.ToString();Culture=$reader.GetString($ref.Culture);
                PublicKeyOrToken=[Convert]::ToHexString($reader.GetBlobBytes($ref.PublicKeyOrToken));Flags=[int]$ref.Flags;
                HashValue=[Convert]::ToHexString($reader.GetBlobBytes($ref.HashValue))}
        })
        [pscustomobject]@{SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;
            MVID=$reader.GetGuid($reader.GetModuleDefinition().Mvid).ToString();References=$refs}
    }
    finally { $pe.Dispose(); $stream.Dispose() }
}
