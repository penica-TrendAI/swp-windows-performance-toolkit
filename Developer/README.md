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

With the pinned vendor bundles and the long publication test enabled, the suite uses generated inputs and includes the desktop button and delayed-publication tests. Omit `-VendorKitRoot` on a source-only checkout to skip the vendor installation test. Omit `-LongPublicationTest` for a shorter run. `-Baseline` selects checks used to compare an older collector revision.

## Change and validate the collector

1. Preserve Windows PowerShell 5.1 compatibility, the complete vendor settings object and its encoding, ownership validation, new/retried case semantics and verified restoration. Run the portable fixture suite with the actual updated source.
2. When updating a vendor build, review the new archive layout, entrypoint and configuration sections, validate its provenance and update the pinned SHA-256 in `Install-BundledTools`. Update the example config only after verifying the applied config for the new build.
3. Keep the validation summary tied to the collector that was actually tested. Build a candidate and install from that archive on a lab machine. Exercise first sign-in after reboot, operator-assisted sign-out/sign-in and recovery after a failed WPR save. Offload and open all three handoffs. Confirm raw and parsed evidence, event loss, time coverage, nested native archive integrity, unrelated recording ownership and cleanup across cases. Check the original machine state after each test.
4. Record actual results, runtime versions, known gaps and script digest in `Validation-summary.json`. Distinguish fixture results from live acceptance. The generated `Package-info.json` identifies whether the packaged collector matches that recorded digest.

## Edit and render the documentation

`Documentation/Handbook.md` is the authoring source. Each level-two heading starts a handbook page. The first page introduces the roles and pages two and six supply the end-user and administrator-participant handouts. Use two-column tables, fenced code blocks, ordinary paragraphs, bold text, inline code and Markdown links. The renderer handles that subset. If section order or page count changes, update the page references in the entry guide and this file and review the participant-sheet extraction.

Rendering is a maintainer task. Use Python 3.10 or later with `python-docx` and `pypdf`, plus LibreOffice for PDF export. In an environment with these packages installed, run the following from the extracted kit. Supply the installed LibreOffice executable path through `--soffice` if it is not on PATH.

```powershell
py -3 .\Developer\render_handbook.py --pdf
```

This produces `Documentation/SWP-Perf-Handbook.docx`, `SWP-Perf-Handbook.pdf` and the participant and solo-administrator PDFs. The solo checklist is also emitted as Markdown. Inspect every rendered page, including code wrapping and table splits. Validate JSON examples and PowerShell syntax on Windows. Compare all documented stages, parameter names, defaults and output paths with the release code. Keep the standalone administrator runbook aligned with the handbook.

## Build and verify the customer ZIP

The download is tracked at `dist/SWP-Customer-Kit.zip`, beside its `.sha256.txt` file. On every push to `main`, the **Update customer kit** workflow builds the allowlisted members from the latest branch contents and verifies every member. If the bytes changed, it commits the ZIP and checksum together. A push affecting only unrelated files leaves the download unchanged. The workflow can also be run manually on `main`.

```powershell
py -3 .\Developer\build_kit.py --refresh
py -3 .\Developer\build_kit.py --check
```

Use `--output C:\SWP-Release\SWP-Customer-Kit.zip` to build at an unused path. Builds use fixed ZIP metadata and member order, so identical inputs yield identical bytes across checkouts. `--check` exits unsuccessfully if the contents or checksum are stale.

`MEMBERS` in the builder defines what ships, including the analysis skill. To add a new distributable file, add it to that list. Handbook edits should include the regenerated Word and PDF versions. The builder copies those reviewed documents as committed.

For an ordinary rebuild, the two vendor tools come from the existing tracked ZIP. A local copy under `Tools` takes precedence. Every copy must match its pinned hash. For a vendor upgrade, supply the new originals locally, update the pins and installer checks, validate the build, then commit the refreshed ZIP alongside the source change. [Vendor prerequisites](../Tools/README.md)

`Package-info.json` in the ZIP gives the packaged collector hash, the collector hash from the last recorded validation and a match flag. A source update refreshes the download immediately after the workflow succeeds. The validation summary changes when maintainers record new results.


### Pass B verification

Exercise the dashboard with a finished, open Pass A case. Verify the optional prepare action, restart instructions, early snapshot, separate notes, Finish B, Package and B-specific recovery after interruption. The manual Procmon steps require an administrator on the Windows desktop. Preserve all PML segments before finishing.

`Procmon/PassB-segments.csv` records the segments observed at finish. Reopen the combined ZIP and check its assessment after removing or replacing a segment in a fixture. Each pass has its own event export manifest. Failed exports for known channels are evidence gaps. Also test recovery before restart and after a boot without a saved PML. A successful archive hash verifies file integrity independently of sign-in timing coverage.

## First sign-in after restart

The pre-restart GUI and CLI share the participant instruction and the case-specific command. `CheckSignInReady` runs on the endpoint through an elevated noninteractive session. It validates the reboot pass, reuses the same signed scan control as the same-boot workflow, and verifies a fresh path-matched pair. The check rejects an occupied console and makes up to three probe attempts. `Trend/<pass>-Cold-signin-control.json` describes the latest check. Only the later sign-in assessment establishes coverage between authentication and Explorer. Fixture tests cover retries, an occupied console, a sign-in during verification, stale proof and both GUI pass instructions.
