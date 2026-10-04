Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-DeterministicMvid {
    <#
    .SYNOPSIS
        Applies a deterministic Module Version ID (MVID) and zeroes PE timestamp.
    .DESCRIPTION
        Clears the PE header TimeDateStamp, locates the MVID in the metadata heap,
        computes SHA-256 over the blanked assembly bytes, formats the first 16 bytes
        as an RFC 4122 v4 variant 1 GUID, and writes it back into the binary.
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]] $Assembly
    )

    if ($Assembly.Length -lt 0x40) {
        throw 'The byte array is too short to be a valid PE file.'
    }

    # COFF header: e_lfanew at 0x3C, then PE signature 'PE\0\0' (0x00004550),
    # then Machine (2 bytes), NumberOfSections (2 bytes), TimeDateStamp (4 bytes).
    $peOffset = [BitConverter]::ToInt32($Assembly, 0x3C)
    if ($peOffset -lt 0 -or $peOffset -ge ($Assembly.Length - 12)) {
        throw 'Invalid e_lfanew PE header offset.'
    }

    if ([BitConverter]::ToUInt32($Assembly, $peOffset) -ne 0x00004550) {
        throw 'The assembly does not carry a valid PE signature where its DOS header points.'
    }

    $timestampOffset = $peOffset + 8
    $result = [byte[]]$Assembly.Clone()
    for ($i = 0; $i -lt 4; $i++) {
        $result[$timestampOffset + $i] = 0
    }

    $stream = [System.IO.MemoryStream]::new($result, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $current = $reader.GetGuid($reader.GetModuleDefinition().Mvid).ToByteArray()
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    # Locate the exact 16-byte MVID occurrence in the binary
    $matches = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le ($result.Length - 16); $i++) {
        if ($result[$i] -ne $current[0]) { continue }
        $same = $true
        for ($j = 1; $j -lt 16; $j++) {
            if ($result[$i + $j] -ne $current[$j]) {
                $same = $false
                break
            }
        }
        if ($same) {
            $matches.Add($i)
        }
    }

    if ($matches.Count -ne 1) {
        throw "The module version id appears $($matches.Count) times in the assembly; exactly one occurrence is required."
    }
    $offset = $matches[0]

    # Blank the 16 MVID bytes for hashing
    $blanked = [byte[]]$result.Clone()
    for ($j = 0; $j -lt 16; $j++) {
        $blanked[$offset + $j] = 0
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($blanked)
    }
    finally {
        $sha256.Dispose()
    }

    $mvid = [byte[]]::new(16)
    [System.Array]::Copy($digest, 0, $mvid, 0, 16)
    # Format as RFC 4122 v4 variant 1 GUID
    $mvid[7] = [byte](($mvid[7] -band 0x0F) -bor 0x40)
    $mvid[8] = [byte](($mvid[8] -band 0x3F) -bor 0x80)

    [System.Array]::Copy($mvid, 0, $result, $offset, 16)
    return ,$result
}
