class LoopsFixture {
    static [int] SumForeach([int[]] $values) {
        [int] $sum = 0
        foreach ($v in $values) {
            $sum += $v
        }
        return $sum
    }

    static [int] LastForeachValue([int[]] $values) {
        [int] $v = -1
        foreach ($v in $values) {
        }
        return $v
    }

    static [int] FirstNegativeIndex([int[]] $values) {
        [int] $found = -1
        for ([int] $i = 0; $i -lt $values.Length; $i++) {
            if ($values[$i] -lt 0) {
                $found = $i
                break
            }
        }
        return $found
    }

    static [int] SumSkippingOdd([int[]] $values) {
        [int] $sum = 0
        foreach ($v in $values) {
            if ($v % 2 -ne 0) {
                continue
            }
            $sum += $v
        }
        return $sum
    }

    static [int] ForContinueStillIterates([int] $n) {
        [int] $count = 0
        for ([int] $i = 0; $i -lt $n; $i++) {
            if ($i % 3 -eq 0) {
                continue
            }
            $count++
        }
        return $count
    }

    static [int] WhileContinue([int] $n) {
        [int] $i = 0
        [int] $sum = 0
        while ($i -lt $n) {
            $i++
            if ($i % 2 -eq 0) {
                continue
            }
            $sum += $i
        }
        return $sum
    }

    static [int] NestedBreakInner([int] $rows, [int] $cols) {
        [int] $visited = 0
        for ([int] $r = 0; $r -lt $rows; $r++) {
            for ([int] $c = 0; $c -lt $cols; $c++) {
                if ($c -ge 2) {
                    break
                }
                $visited++
            }
        }
        return $visited
    }

    static [int] BreakFromTry([int[]] $values) {
        [int] $seen = 0
        foreach ($v in $values) {
            try {
                if ($v -eq 0) {
                    break
                }
                $seen++
            }
            finally {
                $seen += 100
            }
        }
        return $seen
    }

    static [double] AverageDoubles([double[]] $values) {
        [double] $sum = 0.0
        [int] $count = 0
        foreach ($d in $values) {
            $sum += $d
            $count++
        }
        if ($count -eq 0) {
            return 0.0
        }
        return $sum / [double] $count
    }

    static [int] CountChars([string[]] $words) {
        [int] $total = 0
        foreach ($w in $words) {
            $total += $w.Length
        }
        return $total
    }
}
