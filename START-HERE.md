# Windows sign-in and application performance collection

## Start here

Use this kit on the affected Windows computer to record one reboot or full sign-out/sign-in and the agreed application launches.

| Who is running the test? | Instructions |
|---|---|
| Endpoint or Trend policy administrator | Read the [collection guide](Customer-Collection-Guide.pdf). The [administrator runbook](Customer-Runbook.md) includes copyable PowerShell commands, recovery and cleanup. |
| Person experiencing the delay | Use the [one-page timing sheet](Documentation/Participant-sheet.pdf). |
| Administrator testing their own sign-in | Use the [administrator checklist](Documentation/Administrator-participant.pdf). |

**Install.** Download the matching SHA-256 file beside the customer ZIP. Follow “Install and check the kit” in the collection guide to verify the checksum, extract to a fresh folder and run `SWP-Perf.ps1 -Stage InstallTools` in elevated 64-bit Windows PowerShell 5.1. The kit includes the Trend DSA Support Tool CMD for metrics and both WPR recording profiles. If Trend support specifically requests its separate GUI, the runbook explains how to download it.

**Collect.** Open **SWP Performance Collector** from Start or choose a PowerShell stage. For a delayed reboot test, wait two minutes from when the sign-in screen appears. Stop the trace once the agreed desktop or application milestone is reached. Enter timing notes, then finish and package the case. An optional Pass B requires Microsoft Process Monitor as described in the runbook.

**Return.** Send the verified `AllEvidence-CASE-…zip` and matching checksum from `C:\SWP-Handoff` through the agreed support channel. Restore the recorded protection settings and follow the cleanup instructions after verifying transfer.
