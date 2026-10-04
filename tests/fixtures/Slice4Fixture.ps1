class Slice4Fixture {
    static [bool] IntEqual([int] $a, [int] $b) {
        return $a -eq $b
    }

    static [bool] IntLess([int] $a, [int] $b) {
        return $a -lt $b
    }

    static [bool] IntLessOrEqual([int] $a, [int] $b) {
        return $a -le $b
    }

    static [bool] IntGreaterOrEqual([int] $a, [int] $b) {
        return $a -ge $b
    }

    static [bool] FloatLessOrEqual([double] $a, [double] $b) {
        return $a -le $b
    }

    static [bool] LogicalAnd([bool] $a, [bool] $b) {
        return $a -and $b
    }

    static [bool] LogicalOr([bool] $a, [bool] $b) {
        return $a -or $b
    }

    static [bool] LogicalNot([bool] $a) {
        return -not $a
    }
}
