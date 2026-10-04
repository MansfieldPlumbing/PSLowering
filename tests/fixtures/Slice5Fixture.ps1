class Slice5Fixture {
    static [int] BranchMax([int] $a, [int] $b) {
        if ($a -gt $b) {
            return $a
        }
        else {
            return $b
        }
    }

    static [int] NestedIf([int] $x) {
        if ($x -gt 0) {
            if ($x -gt 100) {
                return 2
            }
            return 1
        }
        elseif ($x -lt 0) {
            return -1
        }
        else {
            return 0
        }
    }

    static [int] SumTo([int] $n) {
        $sum = 0
        for ($i = 1; $i -le $n; $i++) {
            $sum = $sum + $i
        }
        return $sum
    }

    static [int] EarlyReturnInLoop([int] $target) {
        for ($i = 0; $i -lt 100; $i++) {
            if ($i -eq $target) {
                return $i * 10
            }
        }
        return -1
    }

    static [int] WhileCountdown([int] $start) {
        $count = 0
        while ($start -gt 0) {
            $start = $start - 1
            $count = $count + 1
        }
        return $count
    }
}
