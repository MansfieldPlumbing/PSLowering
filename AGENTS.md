# PSPersistence repository contract

Keep this repository narrow and evidence-led.

- `experiments/` contains explicitly bounded persistence experiments.
- `probes/` contains read-only runtime observation probes.
- `tests/` contains executable verification.
- `build/` contains generated output and is never source.

Do not vendor upstream repositories, generated assemblies, SDK headers, donor
code, graphics work, JavaScript parsing work, Android packaging, or unrelated
application archaeology here.

PowerShell must continue to parse and compile through authentic
`System.Management.Automation`. Do not describe experiments as a replacement
PowerShell compiler or as generally supported conversion. Every capability
claim must identify and pass an executable verification boundary.
