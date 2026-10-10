# Frozen legacy baseline

`218f54e.json` was reconstructed from immutable commit
`218f54e60e7750dc28576dfdb51cebbadad7fa9f`, using PowerShell
7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128 on Windows x64.
The original 19-suite runner passed. All 52 deterministic output records
and 14 diagnostics agreed with the earlier ignored consolidation evidence.
Two nondeterministic SMA experiment assemblies and one additional smoke
output in the old capture are outside that historical 52-output corpus.

The manifest records the baseline compiler's SHA-256, each compilation
recipe, assembly SHA-256, MVID, full ordered assembly-reference records,
and the exact rejected source and diagnostic including line/column.
The oracle/source-oracle directories are historical aliases; each is now
rebuilt independently from its declared fixture, rather than read from a
possibly stale output directory.

To independently reconstruct the evidence, export the baseline commit with
`git archive` to an ignored directory, run its original consolidated runner
with the pinned toolchain and standalone runtime, then compile each manifest
recipe with that exported compiler. Use the recipe's output filename (the
assembly name), ClassName and optional EntryPoint. Read hashes and metadata
with `tests/LegacyMetadata.ps1`. Compile each frozen rejection source with
that compiler and compare the complete exception message, normalizing only
CRLF to LF. Reconstruction is a manual audit, not a mode of the verifier.

`tests/Test-LegacyRatchet.ps1` rebuilds all outputs in ignored
`build/legacy-ratchet`, independently reads their hashes and metadata, and
compares exact diagnostic text. It has no baseline-writing mode. It also
alters copies of an expected hash and diagnostic and proves that both the
comparator and child verifier process fail. Full evidence remains under
ignored build/. CI prints sanitized outcomes and uploads no artifacts.

Never update these expected values to make a regression pass. An intentional
legacy change requires a documented justification and Scott's explicit
approval. New native fixtures are separately verified and do not alter this
baseline.
