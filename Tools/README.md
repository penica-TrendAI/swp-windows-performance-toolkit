# Trend support tool prerequisites

The customer kit includes the pinned DSA Support Tool CMD for normal collection. Install from a fresh extraction of `dist/SWP-Customer-Kit.zip`, or supply its original CMD archive under `Tools` for a source installation. The builder can also reuse this archive from the tracked customer ZIP.

The vendor GUI is optional. If Trend support requests a GUI diagnostic, sign in to the Business Support Portal, open **Diagnostic Tools**, and download the current Windows DSA Support Tool **GUI**. For a separate capture, extract that package into its own folder and follow the administrator runbook. If supplying the older pinned GUI archive to the toolkit installer, use the exact name and hash below. [Trend download and usage instructions](https://success.trendmicro.com/en-US/solution/KA-0012444)

| Local filename | Expected SHA-256 |
|---|---|
| `DSASupportTool-CMD.zip` | `17297b8abb8193d7552c4a0023723ed0fee29b93849b97c91dc69300e6520c42` |
| `DSASupportTool-GUI.zip` | `090e62db8cd47663a314a0778083a18941dfe885715fa18a28d795508b9ed68f` |

From the repository root in Windows PowerShell, verify the downloads and install the collector in an elevated session.

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '.\Tools\DSASupportTool-CMD.zip'
.\SWP-Perf.ps1 -Stage InstallTools
```
