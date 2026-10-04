class VoiceRowIndexContract {
    static [int] VoiceRowIndex([int] $phonemeCount) {
        if ($phonemeCount -lt 1 -or $phonemeCount -gt 510) {
            throw [System.ArgumentOutOfRangeException]::new(
                "phonemeCount",
                "Phoneme count must be between 1 and 510."
            )
        }
        return $phonemeCount - 1
    }

    static [bool] SynthesisReady() {
        return $true
    }
}
