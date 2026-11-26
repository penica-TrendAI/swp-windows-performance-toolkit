# Trend support tool prerequisites

Obtain the original Windows CMD and GUI archives for DSA Support Tool build **1.0.0.1203** through Trend support. Keep the ZIPs intact and place them beside this file using the exact names below. The installer checks both SHA-256 values. If Trend supplies another build, follow the update and validation procedure in the developer guide before using it. [Trend DSA Support Tool](https://success.trendmicro.com/en-US/solution/KA-0012444) · [Developer guide](../Developer/README.md)

| Local filename | Expected SHA-256 |
|---|---|
| `DSASupportTool-CMD.zip` | `17297b8abb8193d7552c4a0023723ed0fee29b93849b97c91dc69300e6520c42` |
| `DSASupportTool-GUI.zip` | `090e62db8cd47663a314a0778083a18941dfe885715fa18a28d795508b9ed68f` |

From the repository root in Windows PowerShell, verify the downloads and install the collector in an elevated session.

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '.\Tools\DSASupportTool-CMD.zip', '.\Tools\DSASupportTool-GUI.zip'
.\SWP-Perf.ps1 -Stage InstallTools
```

These archives are local build inputs. Obtain any additional tools required for optional analysis from their publisher.
