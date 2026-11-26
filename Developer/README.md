# Maintaining the SWP performance collector

Start with pages 16–22 of the [handbook](../Documentation/SWP-Perf-Handbook.pdf) for the public interface, implementation map, recovery boundaries and release tests. The editable [handbook source](../Documentation/Handbook.md) and [administrator runbook](../Customer-Runbook.md) accompany the same collector that installs on the endpoint.

## Work from the distribution

Use an extracted working copy on a Windows test machine. The top level contains `SWP-Perf.ps1`, the two WPR profiles, `Validation-summary.json`, the operator documentation and `Tools`. `CollectionScript.Tests.ps1` in this directory imports functions from the top-level collector by parsing its AST. Run the production collector through `-Stage` at its normal entry point for a real acceptance test. Use a dedicated results folder for each test run.

## Desktop and command-line routing

The dispatcher resolves the case and runs the requested stage. The WPF window launches the same script in a local background job with explicit parameters and streams stage output. The window loads desktop assemblies only on its GUI path. Help, Status and the scheduled metrics worker run headlessly. The active identity is in `Cleanup\PhaseA-state.json`. Cleanup with retained evidence records the run ID in `Cleanup\Collector-closed.json` after restoration. Existing case records from the prior release use ConfigRestored. A machine-wide mutex serializes operator changes. Status, the scheduled worker and the early debug snapshot can run while their parent stage is active.

## Run the portable Windows fixtures

Use elevated 64-bit **Windows PowerShell 5.1** and your organization's approved script execution process. These commands assume a full extraction at `C:\SWP-Customer-Kit`. The fixture tests create temporary work directories. Real boot, sign-in, service restart and WPR ownership still require validation on a Trend-protected Windows test machine.

```powershell
$kit = (Resolve-Path 'C:\SWP-Customer-Kit').Path
$harness = Join-Path $kit 'Developer\CollectionScript.Tests.ps1'
$out = Join-Path $env:TEMP ('SWP-TestResults-' + (Get-Date -Format yyyyMMdd-HHmmss))
& $harness -SourcePath (Join-Path $kit 'SWP-Perf.ps1') `
    -VendorKitRoot $kit -ResultsFolder $out -LongPublicationTest
$r = Get-Content -LiteralPath (Join-Path $out 'Regression-results.json') -Raw |
    ConvertFrom-Json
$r.Results | Group-Object Status | Select-Object Name, Count
$r | Select-Object PowerShell, SourceSHA256, SourceSHA256After, SourceChangedDuringRun
```

With the pinned vendor bundles and the long publication test enabled, the suite runs **45 tests** using generated inputs. Omit `-VendorKitRoot` on a source-only checkout to skip the vendor installation test. Omit `-LongPublicationTest` for a shorter run. `-Baseline` selects checks used to compare an older collector revision.

## Change and validate the collector

1. Preserve Windows PowerShell 5.1 compatibility, the complete vendor settings object and its encoding, ownership validation, new/retried case semantics and verified restoration. Run the portable fixture suite with the actual updated source.
2. When updating a vendor build, review the new archive layout, entrypoint and configuration sections, validate its provenance and update the pinned SHA-256 in `Install-BundledTools`. Update the example config only after verifying the applied config for the new build.
3. Set the candidate summary to the new collector digest and identify the live tests as pending. Rebuild a candidate and install from that archive on a lab machine. Exercise first sign-in after reboot, operator-assisted sign-out/sign-in and recovery after a failed WPR save. Offload and open all three handoffs. Confirm raw and parsed evidence, event loss, time coverage, nested native archive integrity, unrelated recording ownership and cleanup across cases. Check the original machine state after each test.
4. Record actual results, runtime versions, known gaps and script digest in `Validation-summary.json`. Distinguish fixture results from live acceptance. A stale summary for a different collector hash causes the packager to stop.

## Edit and render the documentation

`Documentation/Handbook.md` is the authoring source. Each level-two heading starts a handbook page. The first page introduces the roles and pages two and six supply the end-user and administrator-participant handouts. Use two-column tables, fenced code blocks, ordinary paragraphs, bold text, inline code and Markdown links. The renderer handles that subset. If section order or page count changes, update the page references in the entry guide and this file and review the participant-sheet extraction.

Rendering is a maintainer task. Use Python 3.10 or later with `python-docx` and `pypdf`, plus LibreOffice for PDF export. In an environment with these packages installed, run the following from the extracted kit. Supply the installed LibreOffice executable path through `--soffice` if it is not on PATH.

```powershell
py -3 .\Developer\render_handbook.py --pdf
```

This produces `Documentation/SWP-Perf-Handbook.docx`, `SWP-Perf-Handbook.pdf` and the participant and solo-administrator PDFs. The solo checklist is also emitted as Markdown. Inspect every rendered page, including code wrapping and table splits. Validate JSON examples and PowerShell syntax on Windows. Compare all documented stages, parameter names, defaults and output paths with the release code. Keep the standalone administrator runbook aligned with the handbook.

## Build and verify a distributable ZIP

The support analyst’s instructions ship at `skills/analyze-swp-performance/SKILL.md`. The package builder reads it directly from this repository and verifies the archived bytes.

Supply the pinned local archives as described in [vendor prerequisites](../Tools/README.md). The build utility uses only the Python standard library. From the extracted kit, choose a new output path outside the working copy. The utility lists shipping files explicitly, checks the collector digest against the validation summary, reads back all members and creates a sibling SHA-256 file. It rejects an existing archive or checksum at the destination. Keep customer archives, paths and lab capture logs out of the distribution.

```powershell
py -3 .\Developer\build_kit.py --output C:\SWP-Release\SWP-Customer-Kit.zip
Get-FileHash -LiteralPath 'C:\SWP-Release\SWP-Customer-Kit.zip' -Algorithm SHA256
```

Compare that hash with the first field of `SWP-Customer-Kit.zip.sha256.txt`. Extract the finished ZIP into a fresh directory, open the PDF and verify the flat install layout with the script and both WPR profiles beside `Tools`. Documentation-only releases have new ZIP checksums. The collector digest identifies the tested script across those releases. The dated lab validation includes Windows 11 and core 20.0.3-31610. Confirm the relevant build on an affected computer before extending the compatibility claim.
