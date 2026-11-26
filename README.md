# SWP Windows Performance Toolkit

Investigate slow Windows sign-ins and first application launches on endpoints running TrendAI Vision One Server & Workload Protection or Deep Security Agent. The collector records Windows activity with WPR and gathers agent metrics, available per-file scan timings, event logs and a native Trend diagnostic into a verified case archive.

## Customer download

**[Download the full customer ZIP](https://github.com/penica-TrendAI/swp-windows-performance-toolkit/raw/refs/heads/main/dist/SWP-Customer-Kit.zip)** · [Matching SHA-256 checksum](https://raw.githubusercontent.com/penica-TrendAI/swp-windows-performance-toolkit/main/dist/SWP-Customer-Kit.zip.sha256.txt)

Save both files in the same folder. From that folder in Windows PowerShell, verify the download before extraction.

```powershell
$expected = ((Get-Content -LiteralPath '.\SWP-Customer-Kit.zip.sha256.txt' -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath '.\SWP-Customer-Kit.zip' -Algorithm SHA256).Hash -ne $expected) {
    throw 'The checksum differs. Download the ZIP and its matching checksum again.'
}
```

## Run a capture

1. Extract the complete customer kit into a new local folder. It contains both pinned Trend support tools. For a source-only installation, follow the [vendor prerequisites](Tools/README.md).
2. Open elevated **64-bit Windows PowerShell 5.1** on the affected endpoint. From the extracted folder run `.\SWP-Perf.ps1 -Stage InstallTools`.
3. Use **SWP Performance Collector** in Start, or use the CLI below. Follow the administrator runbook for protection settings, baseline timings and when to stop the trace. [Administrator runbook](Customer-Runbook.md)

```powershell
$swp = Join-Path $env:ProgramFiles 'SWP-PerfTools\SWP-Perf.ps1'
& $swp -Stage Help
```

A typical capture uses **Prepare → reproduce → StopTrace → FinishAndPackage**. Choose a reboot or a full sign-out and sign-in. Prepare allocates a case number and subsequent stages resume the active case. At the agreed milestone, stop WPR promptly. Complete the operator notes before packaging. Transfer the verified ZIP and checksum through the agreed private support channel. After transfer, `Cleanup -KeepEvidence` restores local settings and retains the files. Plain `Cleanup` operates on all local cases.

## Documentation and analysis

| Audience | Guides |
|---|---|
| Participant or endpoint administrator | [Start here](START-HERE.md) · [Handbook](Documentation/SWP-Perf-Handbook.pdf) · [Administrator testing their own account](Documentation/Administrator-participant.md) |
| Support analyst | [Evidence analysis workflow](skills/analyze-swp-performance/SKILL.md) · [Offline WPR export helper](Analysis/README.md) |
| Maintainer | [Build, tests and packaging](Developer/README.md) · [Validation summary](Validation-summary.json) |

WPR shows which processes accessed files. Per-file engine duration requires matching Trend scan records for the same interval. If detailed logging starts after sign-in, report the missing coverage. Use the assessment, operator timestamps and trace loss to interpret each handoff.

Keep case archives, trace exports, user paths and policy data in private case storage. Use synthetic examples for public issues and contributions.
