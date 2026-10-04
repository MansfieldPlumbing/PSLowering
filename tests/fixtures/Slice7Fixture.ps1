class Slice7Fixture {
    static [int] StaticMath([int] $a, [int] $b) {
        return [System.Math]::Max($a, $b)
    }

    static [string] SubstringTest([string] $s, [int] $start, [int] $len) {
        return $s.Substring($start, $len)
    }

    static [string] BuildGreeting([string] $name) {
        $sb = [System.Text.StringBuilder]::new("Hello, ")
        $sb.Append($name)
        $sb.Append("!")
        return $sb.ToString()
    }

    static [bool] IsEmpty([string] $s) {
        return $s -eq [string]::Empty
    }

    static [string] PathCombine([string] $p1, [string] $p2) {
        return [System.IO.Path]::Combine($p1, $p2)
    }
}
