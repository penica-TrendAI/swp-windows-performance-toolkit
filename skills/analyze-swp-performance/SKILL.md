---
name: analyze-swp-performance
description: Analyze customer evidence from SWP-Perf.ps1 for slow Windows sign-in or application launches on endpoints running TrendAI Vision One Server & Workload Protection or Deep Security Agent. Use for full AllEvidence handoffs, partial diagnostics, trace correlation, scan timing analysis, and customer performance reports.
---

# Analyze Windows sign-in and application performance

Work from the supplied case. Derive customer, host, account, time zone, Windows build, agent build, collector revision, scenario and reproduction times from its evidence. Use earlier reports only for layout. Keep each customer’s evidence, findings and exports in a separate case directory.

## Receive and scope the evidence

1. Preserve the original archives. Verify the full AllEvidence ZIP against its supplied SHA-256 with Get-FileHash or an equivalent. For a mismatch, request the matching pair before relying on the archive. For a missing checksum, record the locally computed hash and mark transfer verification pending.
2. Extract a working copy. Read Evidence-assessment.json, the latest Packaging-summary, File-inventory.csv and operator notes. Check actual files and time coverage independently of the collector’s success label. Older kits can have different paths or lack assessments. Locate equivalent raw artifacts and record which checks are possible.
3. If only a native diagnostic or metrics ZIP arrived, analyze the available agent data, state its time window, and identify the additional evidence needed for each unanswered question. Keep different hosts, boots, retries, collection passes and later diagnostics distinguishable.

For an optional Procmon repeat, read `Procmon/Operator-notes.json`, `Procmon/SignIn-milestones.json`, `Trend/PassB-Timed-scans.csv` and `PassBSignInScans` together. Verify the saved PML segments against `Procmon/PassB-segments.csv`. Compare `Events/Channel-exports.csv` for A and `Events/PassB/Channel-exports.csv` for B. Report timing coverage and scan totals separately for each reproduction.

## Map evidence to the investigation

| Case-relative artifact | Tool and purpose |
|---|---|
| Operator-notes.json, Test-notes.txt, WPR/SignIn-milestones.json | Use PowerShell or Python to align reported times with Windows authentication, session identity and Explorer startup. Preserve timestamp precision and source. |
| WPR/PassA-BootLoginApps.etl, WPR/Trace-quality.json | Use Windows Performance Analyzer on a Windows analysis host. Check trace bounds, available providers and event loss. Inspect process lifetimes, parent/child relationships, logical file I/O and physical disk I/O inside each symptom window. Analyze CPU samples or scheduler waits only when the necessary events exist. |
| Trend/Timed-scans.csv, Trend/AMDebug | Use PowerShell or Python to verify paired scan starts and completions against raw log generations and rank scans by window. |
| Trend/LiveMetrics/PassA, Trend/PassA/VerifiedToolMetrics/Metrics-assessment.json, AgentMetrics and SupportToolSnapshot under that pass | Verify embedded host, timestamps, cadence, gaps and overlap. Distinguish run-specific tool samples from ordinary agent telemetry. |
| Trend/FinalDiagnostics | Inspect request status, archive identity, raw log generations and any Top 10 scan report. Determine which records overlap the reproduction and which came later. |
| Events/, Context/, Cleanup/ | Read EVTX with Get-WinEvent -Path or Event Viewer. Correlate logon, profile, Group Policy and scheduled-task activity with process lifetimes. Check policy exports, task XML, scripts and restoration evidence when relevant. Identify which account a gpresult export describes. |
| Optional Pass B PML segments | Use Sysinternals Process Monitor to inspect paths, operations, durations and process relationships for that separate reproduction. |

Use xperf or WPA exports when a repeatable table is needed. Inspect any existing export script for hard-coded case paths, trace sizes, provider assumptions and time ranges before reuse. If Windows trace tools are unavailable, complete the other analysis and identify which ETL questions remain open.

## Correlate timing and test attribution

- Normalize times to UTC for joins and report local time with its UTC offset. Record the evidence source and uncertainty for each boundary. Separate authentication to Explorer, credential submission to usable desktop, and launch to ready for each application. Use operator-observed readiness where supplied. Leave unknown endpoints open.
- Build a coverage table per symptom interval for ETL, event logs, paired scans and metrics. Record first and last timestamps, internal gaps, trace loss and unknowns. Verify the host, boot and session before accepting an overlap flag. Mark scans crossing a boundary separately and document how they were counted.
- Pair raw AMSP scan starts and completions by process/thread and sequence. Preserve path, timestamps, source and engine duration. Deduplicate repeated copies across snapshots while retaining genuine repeat scans. Convert microseconds to milliseconds by dividing by 1,000.
- For every observed path, retain timed count, maximum and summed observed engine milliseconds per interval. Preserve summary-only paths with blank cumulative timing. Keep frequency and last-duration observations separate. Never reconstruct cumulative time by multiplying count by last duration.
- Distinguish concurrent engine time, accumulated process CPU time and elapsed user wait. Investigate other work active during the same delay. When individual scan records start after the symptom, label the interval unverified for scan attribution. Avoid converting missing records into a zero or a causal finding.
- Recommend an exclusion trial only when the evidence shows material scan cost during the symptom and the effective policy supports the proposal. Record the narrow target, owner, risk, rollback and measured success criterion. Compare equivalent runs using the same user, sign-in route, application and readiness definition. Leave policy changes to the customer’s policy owner.

## Produce and verify the customer report

Deliver matching Markdown and Word reports plus supporting CSVs. Lead with the observed delay, the best-supported explanation and any gap that affects the decision. Include case scope, capture quality, a timeline, findings for sign-in and each application, competing explanations, and prioritized next steps. Tie each material finding to an artifact, time range, metric and unit. Distinguish observed activity, suspected contribution and effects demonstrated by a controlled repeat.

Supply CSVs for interval coverage, the event and process timeline, deduplicated individual scans, and per-file totals including summary-only paths. Include process resource summaries or trial candidates when the evidence supports them. For a partial handoff, supply the tables the available sources support and name the smallest additional capture or export needed.

Before delivery, reconcile report values against the CSVs, confirm units and coverage labels, inspect the rendered Word tables, and check that names, paths, findings and recommendations all belong to the current customer.
