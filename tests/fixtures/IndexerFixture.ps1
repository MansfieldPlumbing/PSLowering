class IndexerFixture {
    static [int] ListReadWrite([int[]] $values, [int] $at) {
        $list = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $list.Add($v) }
        $list[$at] = $list[$at] * 10
        return $list[$at] + $list[0]
    }

    static [int] ListCompound([int[]] $values) {
        $list = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $list.Add($v) }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $list[$i] += 5
            $list[$i] *= 2
            $list[$i]++
        }
        $list[-1] -= 100
        --$list[0]
        $sum = 0
        for ($i = 0; $i -lt $list.Count; $i++) { $sum += $list[$i] }
        return $sum
    }

    static [int] ListIncrementValue([int[]] $values) {
        $list = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $list.Add($v) }
        [int] $before = $list[0]++
        [int] $after = ++$list[0]
        return $before * 1000 + $after * 10 + $list[0]
    }

    static [long] ListScanStarts([int[]] $words, [int] $mask) {
        # The shape of a scan over encoded instruction words: record the
        # positions that match, then read them back through the list.
        $starts = [System.Collections.Generic.List[int]]::new()
        for ($w = 0; $w -lt $words.Length; $w++) {
            if (($words[$w] -band $mask) -eq 0) { $starts.Add($w) }
        }
        [long] $total = 0
        for ($w = 0; $w -lt $starts.Count; $w++) {
            $total += [long]$words[$starts[$w]] * [long]($w + 1)
        }
        return $total
    }

    static [int] ListIndexConversion([int[]] $values, [double] $at) {
        $list = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $list.Add($v) }
        return $list[$at]
    }

    static [int] InterfaceNegativeIndex([int[]] $values) {
        $source = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $source.Add($v) }
        [System.Collections.Generic.IList[int]] $list = $source
        $list[-2] = $list[-1] + 1
        return $list[-2]
    }

    static [double] ListOfDouble([int] $count) {
        $list = [System.Collections.Generic.List[double]]::new()
        for ($i = 0; $i -lt $count; $i++) { $list.Add(0.5) }
        for ($i = 0; $i -lt $count; $i++) { $list[$i] = $list[$i] + [double]$i }
        [double] $sum = 0
        for ($i = 0; $i -lt $count; $i++) { $sum += $list[$i] }
        return $sum
    }

    static [long] DictionaryReadWrite([string[]] $keys) {
        $counts = [System.Collections.Generic.Dictionary[string, long]]::new()
        foreach ($k in $keys) { $counts[$k] = $counts[$k] + [long]1 }
        return $counts['a'] * [long]100 + $counts['b'] * [long]10 + $counts['missing']
    }

    static [long] DictionaryCompound([string[]] $keys) {
        $counts = [System.Collections.Generic.Dictionary[string, long]]::new()
        foreach ($k in $keys) {
            $counts[$k] += [long]2
            $counts[$k]++
        }
        [long] $total = 0
        foreach ($k in $keys) { $total += $counts[$k] }
        return $total
    }

    static [string] DictionaryOfString([int] $n) {
        $names = [System.Collections.Generic.Dictionary[int, string]]::new()
        $names[1] = 'one'
        $names[2] = 'two'
        return $names[$n]
    }

    static [char] StringIndex([string] $text, [int] $at) {
        return $text[$at]
    }

    static [int] ReadOnlyListIndex([int[]] $values) {
        $list = [System.Collections.Generic.List[int]]::new()
        foreach ($v in $values) { $list.Add($v) }
        $view = $list.AsReadOnly()
        return $view[0] + $view[-1]
    }

    static [int] ArrayElementIncrement([int[]] $values) {
        $values[0]++
        $values[-1] += 3
        return $values[0] * 100 + $values[-1]
    }
}
