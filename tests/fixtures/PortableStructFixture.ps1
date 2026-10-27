class PortableStructFixture {
    [PortableCounter] $StoredCounter
    static [int] Parameter([PortableCounter] $counter) { return $counter.Scale(3) + $counter.get_Item(2) + $counter.Current }
    static [int] Local([PortableCounter] $counter) {
        $copy = $counter
        return $copy.Scale(3) + $copy.get_Item(2) + $copy.Current
    }
    static [int] Array([PortableCounter[]] $counters) { return $counters[-1].Scale(3) + $counters[0].get_Item(2) }
    [int] Field() { return $this.StoredCounter.Scale(3) + $this.StoredCounter.get_Item(2) + $this.StoredCounter.Current }
    static [string] Virtual([PortableCounter] $counter) { return $counter.ToString() }
    static [int] PropertySetter([PortableCounter] $counter) { $counter.Current = 11; return $counter.Current }
    static [int] IndexerSetter([PortableCounter] $counter) { $counter.set_Item(0, 13); return $counter.get_Item(0) }
    static [int] Choose([int] $value) { return [PortableInference]::Choose($value) }
    static [int] Nested([System.Collections.Generic.List[int[]]] $value) { return [PortableInference]::Nested($value) }
}
