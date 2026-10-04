class Slice8Fixture {
    static [int] ThrowPositive([int] $val) {
        if ($val -lt 0) {
            throw [System.ArgumentOutOfRangeException]::new("val", "must be non-negative")
        }
        return $val * 2
    }

    static [int] TryCatchParse([string] $s, [int] $fallback) {
        try {
            return [int]::Parse($s)
        }
        catch [System.FormatException] {
            return $fallback
        }
    }

    static [int] TryFinallyExecution([int] $initial) {
        $val = 0
        try {
            $val = $initial + 10
            return $val
        }
        finally {
            $val = $val + 100
        }
    }

    static [int] MultiCatch([string] $s) {
        try {
            if ($s -eq "null") {
                throw [System.ArgumentNullException]::new("s")
            }
            return [int]::Parse($s)
        }
        catch [System.ArgumentNullException] {
            return -1
        }
        catch [System.FormatException] {
            return -2
        }
    }
}
