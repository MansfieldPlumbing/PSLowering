class PwshNativeHost {
    # Pwsh setup.ps1 New-FindProfileMethod: the first of files, from index on,
    # whose file name is Profile.ps1 ignoring case; otherwise fallback.
    static [string] FindProfile([string[]] $files, [int] $index, [string] $fallback) {
        for ([int] $i = $index; $i -lt $files.Length; $i++) {
            [string] $name = [System.IO.Path]::GetFileName($files[$i])
            if ([string]::Equals($name, 'Profile.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $files[$i]
            }
        }
        return $fallback
    }
}
