# SWP performance collection kit

Open [the handbook PDF](Documentation/SWP-Perf-Handbook.pdf) for installation, collection, troubleshooting and development. It covers Windows sign-in and first application launches on a computer protected by TrendAI Vision One Server & Workload Protection or Deep Security Agent.

| I am… | Open this first |
|---|---|
| The person experiencing the delay | [One-page participant instructions](Documentation/Participant-sheet.pdf). For per-file scan timings after restart, stay at the sign-in screen until IT gives the go-ahead. |
| The Windows administrator | [Administrator runbook](Customer-Runbook.md) and handbook pages 3–10. |
| The administrator signing in to my own account | [Checklist for an administrator testing their own account](Documentation/Administrator-participant.pdf), also in [copyable Markdown](Documentation/Administrator-participant.md). One person can run and reproduce the test. |
| The Trend policy administrator | Handbook page 8, “Policy context and protection”, followed by the restoration checks on page 10. |
| The support analyst | [Evidence analysis instructions](skills/analyze-swp-performance/SKILL.md) and handbook pages 11–12, “Read the evidence” and “Interpret scan times”. |
| The developer or release maintainer | [Developer guide](Developer/README.md), handbook pages 16–22 and [validation summary](Validation-summary.json). |

The handbook is also available in [Word](Documentation/SWP-Perf-Handbook.docx) and [Markdown](Documentation/Handbook.md). The collector and WPR profiles install from the extracted kit. The full customer ZIP includes both verified support-tool archives. In a Git checkout, the ZIP and SHA-256 file are in `dist`. For installation directly from source, see the [vendor prerequisites](Tools/README.md). The Developer folder is for maintenance.

Endpoint administrators should use 64-bit Windows PowerShell 5.1. Follow the runbook from the extracted folder, starting with `InstallTools`. After installation, use **SWP Performance Collector** in Start or keep using PowerShell with explicit `-Stage` commands. Either route can resume the same capture after sign-in. Give participants the one-page sheet. The expected return is the full `AllEvidence-CASE-…zip` plus its matching checksum through the agreed support channel. Cleanup can delete **all cases** under `C:\SWP-Perf`. Verify the transferred evidence first.

Documentation edition 26 November 2026. Collector revision 26 November 2026. The validation summary identifies the actual Windows and Trend agent versions used.
