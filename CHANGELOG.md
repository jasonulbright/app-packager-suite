# Changelog

## [Unreleased]

### SuiteCommon

- Darken the title bar of an inactive window so that the white title text reaches 4.5:1: `#5F6B7A` in the light theme (was `#4BA3E0`, 2.8:1) and `#6B6B6B` in the dark theme (was the MahApps `#808080`, 3.9:1).
- Add SuiteCommon.Contrast.Tests.ps1. It checks the contrast of the palette pairs (text 4.5:1, borders 3:1) and creates no window.

## [2026.11.13.0083] - 2026-11-13

## 12 components refreshed

### Installer

- Carry all twelve components: App Packager 2026.11.13.0137, Collection Manager 2026.11.13.0022, Collection and Compliance Manager 2026.11.13.0018, Deployment Helper 2026.11.13.0022, Detection Method Tester 2026.11.13.0017, Device Inspector 2026.11.13.0012, DP Content Manager 2026.11.13.0018, Installer Analysis 2026.11.13.0024, Maintenance Window Manager 2026.11.13.0019, Pivots and Scripts 2026.11.13.0011, Site Hygiene 2026.11.13.0034 and Update Planner 2026.11.13.0007.
- Show the site code and the site server in the footer of every tool that connects to ConfigMgr, in one shared footer style.
- Restore the weight of headers and status text. Bold stays on field titles and sidebar app titles.
- Edit the site code and the site server only in the Options window, the launcher and the first-run window. The footer shows them as text.
- Retake the guide images in the light and the dark theme.

### SuiteCommon

- Add the shared footer: one style for all footer text (Segoe UI 11, normal weight and style, same in light and dark) and the connection text Site MCM · cm01.contoso.com (Initialize-SuiteFooter, Update-SuiteFooter, Format-SuiteFooterSite, Get-SuiteFooterStyle).

### Launcher

- Show the site code and the site server in the launcher footer, in the shared footer style. The status text no longer sets its own font size. The two boxes in the main window stay the place to edit them. Add a guard test for the launcher footer.

## [2026.11.13.0082] - 2026-11-13

## 12 components refreshed

### Installer

- Carry all twelve components: App Packager 2026.11.13.0135, Collection Manager 2026.11.12.0021, Collection and Compliance Manager 2026.11.12.0017, Deployment Helper 2026.11.12.0021, Detection Method Tester 2026.11.12.0016, Device Inspector 2026.11.13.0011, DP Content Manager 2026.11.12.0017, Installer Analysis 2026.11.12.0023, Maintenance Window Manager 2026.11.12.0018, Pivots and Scripts 2026.11.12.0010, Site Hygiene 2026.11.12.0033 and Update Planner 2026.11.12.0006.
- Show white text on every blue box in the light theme, in every tool.
- Show the Site Code and SMS Provider titles in bold 14 pt in both themes. The values keep the normal style.
- Use one themed button style in every window and dialog, with a visible border on hover.
- Keep raw error text out of every window. The log file holds it.
- Use Title Case for buttons, headers and dialog titles, and one short sentence for each tooltip.
- Retake the guide images in the light and the dark theme.

## [2026.11.12.0081] - 2026-11-12

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.12.0133. The other eleven components are unchanged.
- App Packager 0133: rebuild the CVE lookup on full NVD product records; correct 21 CPE names.
- Raise the dark button border to 3:1 and test the state contrast pairs.
- Bold the field titles of site code and provider, not their values.
- Fix light theme white text on blue boxes; bold 14 pt site code and provider.

## [2026.11.11.0080] - 2026-11-11

## 1 component refreshed

### Installer

- Carry Device Inspector 2026.11.11.0010. The other eleven components are unchanged.
- Device Inspector 0010: show the site inventory scan time as the Last hardware inventory fact, labelled as device local time.
- Device Inspector 0010: name the source of the fact in the JSON export.

## [2026.11.11.0079] - 2026-11-11

## 3 components refreshed

### Installer

- Carry App Packager 2026.11.11.0132, Deployment Helper 2026.11.11.0020 and Device Inspector 2026.11.11.0009. The other nine components are unchanged.
- App Packager 0130: show the full header of every dialog grid column, and widen the Options window.
- App Packager 0131: fix theme colors of buttons, selected list items and disabled fields; dim the title bar of an unfocused dialog; wrap the Workbench action buttons.
- App Packager 0132: no change in the installer. The release adds repository checks only.
- Deployment Helper 0019 and 0020: no change in the installer. The releases add a user guide and repository checks, which the installer does not carry.
- Device Inspector 0006: add nine device and site actions, each with a dry run and an action log, behind an Enable actions switch.
- Device Inspector 0006: add a device list search, a collection browser, and collection membership rules in the report.
- Device Inspector 0007: show the uninstall keys of a device live, and uninstall or repair from the key.
- Device Inspector 0007: filter the Applications panel by type, and remove the Status column.
- Device Inspector 0008: run each action in a background task, with one running action for each device.
- Device Inspector 0008: list the running actions, and warn when the window closes while actions run.
- Device Inspector 0009: end the process after Close anyway, and fix the close warning text.
- Device Inspector 0009: show the version once in the Uninstall and Repair confirmation.

## [2026.11.10.0078] - 2026-11-10

## 2 components refreshed

### Installer

- Carry Update Planner 2026.11.10.0005 and Device Inspector 2026.11.10.0005. The other ten components are unchanged.
- Update Planner and Device Inspector: Options message boxes show the app name, contrast of disabled controls and tab headers is fixed, a local SMS Provider or site server no longer gets a credential, and the user guides are corrected.

## [2026.11.10.0077] - 2026-11-10

## Smaller installer

### Changed

- The installer payload no longer carries each component's `docs` and `screenshots` folders, `screenshot.png`, `.github`, `.coderabbit.yaml` or `Invoke-Checks.ps1`. Release 0075 added the component user guides to the payload, and the installer grew from 5.2 MB to 24.2 MB, mostly screenshots. The guides stay in the component repositories. Only the component root is stripped.
- New tests cover the strip.

## [2026.11.08.0076] - 2026-11-08

## 1 documentation count corrected

### Fixed

- Corrected the README Start Menu description: twelve tool shortcuts plus the launcher shortcut.

## [2026.11.07.0075] - 2026-11-07

## Settings fix in SuiteCommon

### Fixed

- `Read-SuiteSettings` returned no value for a setting named `Keys`. The function read `$Defaults.Keys`, and a hashtable that holds a key named `Keys` returns that key's value instead of its key list. The function now uses `GetEnumerator()`.
- `Read-SuiteSettings` returned 1 for a missing setting named `Count` or `Length` on PowerShell 7. The function now reads only real JSON properties.
- New tests cover the setting names `Keys`, `Values`, `Count` and `Length`.

## [2026.11.06.0074] - 2026-11-06

## 2 components refreshed

### Installer

- Carry Update Planner 2026.11.06.0003 and Device Inspector 2026.11.06.0003. Both read the site with the ConfigurationManager cmdlets and need the Configuration Manager console; the other eleven components are unchanged.

## [2026.11.06.0073] - 2026-11-06

## 2 new tools in the suite

### Installer

- Add Update Planner 2026.11.06.0001 and Device Inspector 2026.11.06.0001; the other eleven components are unchanged.

## [2026.11.06.0072] - 2026-11-06

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.05.0129; the other ten components are unchanged.

## [2026.11.05.0071] - 2026-11-05

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.05.0128; the other ten components are unchanged.

## [2026.11.05.0070] - 2026-11-05

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.05.0127; the other ten components are unchanged.

## [2026.11.05.0069] - 2026-11-05

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.05.0126; the other ten components are unchanged.

## [2026.11.05.0068] - 2026-11-05

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.05.0125; the other ten components are unchanged.

## [2026.11.04.0067] - 2026-11-04

## 1 component refreshed

### Installer

- Carry App Packager 2026.11.04.0124; the other ten components are unchanged.

## [2026.10.29.0066] - 2026-10-29

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.29.0123; the other ten components are unchanged.

## [2026.10.25.0065] - 2026-10-25

## 6 components refreshed

### Installer

- Merge an old install folder into its renamed replacement without losing files.
- Stage the installer build in a temporary folder.

### Launcher

- Report when the connection profile or theme cannot be saved.
- Return a folder selection only when the picker is confirmed.
- Quote tool arguments that contain spaces.

### Components

- Carry App Packager 2026.10.25.0122.
- Carry Installer Analysis 2026.10.25.0018.
- Carry Collection and Compliance Manager 2026.10.25.0013.
- Carry Collection Manager 2026.10.25.0016.
- Carry Deployment Helper 2026.10.25.0018.
- Carry Maintenance Window Manager 2026.10.25.0013; the other four components are unchanged.
## [2026.10.20.0064] - 2026-10-20

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.20.0121; the other ten components are unchanged.

## [2026.10.18.0063] - 2026-10-18

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.18.0120; the other ten components are unchanged.

## [2026.10.17.0062] - 2026-10-17

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.17.0119; the other ten components are unchanged.

## [2026.10.14.0061] - 2026-10-14

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.14.0118; the other ten components are unchanged.

## [2026.10.12.0060] - 2026-10-12

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.12.0117; the other ten components are unchanged.

## [2026.10.12.0059] - 2026-10-12

## 1 component refreshed

### Installer

- Carry Deployment Helper 2026.10.12.0017; the other ten components are unchanged.

## [2026.10.12.0058] - 2026-10-12

## 1 PowerShell 7 fix

### Shared module

- Keep the PowerShell 7 module roots when a tool runs under PowerShell 7.

## [2026.10.11.0057] - 2026-10-11

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.11.0115; the other ten components are unchanged.

## [2026.10.11.0056] - 2026-10-11

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.11.0114; the other ten components are unchanged.

## [2026.10.11.0055] - 2026-10-11

## 1 component refreshed

### Installer

- Carry App Packager 2026.10.11.0113; the other ten components are unchanged.

## [2026.10.11.0054] - 2026-10-11

## 1 window fix

### Shared module

- Double-click the title bar to maximize or restore the window.

## [2026.10.11.0053] - 2026-10-11

## 11 of 11 components refreshed

### Installer

- Carry App Packager 2026.10.11.0111 and the nine tools released today.

### Shared module

- Add the update notice helper every tool calls at window load.

## [2026.10.11.0052] - 2026-10-11

## 1 update check added

### Launcher

- Check for a newer suite release once a day and show an Update banner.
- Download the signed installer, verify its checksum and signature, and install it silently.
- Add a Check for updates button and a Release notes button.

### Shared module

- Add the suite update check, download, verification and installer start for every tool.

## [2026.10.11.0051] - 2026-10-11

## 1 icon fix

### Installer

- Trim the empty border from the suite icon so it fills the taskbar and Software Center tile.

## [2026.10.11.0050] - 2026-10-11

## 1 of 11 components refreshed

### Installer

- Carries App Packager 2026.10.11.0110 with the 0050 shared module version; the other eight components are unchanged.
- Show the suite icon on the setup, the uninstaller and the launcher shortcut.

## [2026.10.07.0049] - 2026-10-07

## 9 of 11 components refreshed

### Installer

- Carries App Packager 2026.10.07.0106 with the 0049 shared module version.
- Carries Site Hygiene 2026.10.07.0025 and Collection and Compliance Manager 2026.10.07.0009.
- Carries Collection Manager 2026.10.07.0012 and Deployment Helper 2026.10.07.0013.
- Carries Detection Method Tester 2026.10.07.0009 and DP Content Manager 2026.10.07.0009.
- Carries Installer Analysis 2026.10.07.0014 and Maintenance Window Manager 2026.10.07.0009.
- Carries Pivots and Scripts 2026.10.01.0002 unchanged.

## [2026.10.07.0048] - 2026-10-07

## 1 of 11 components refreshed

### Installer

- Carries collection-manager 2026.10.07.0011 with reusable site WQL query management.
- Ships the other ten components unchanged.

## [2026.10.07.0047] - 2026-10-07

## 2 of 11 components refreshed

### Installer

- Carries app-packager 2026.10.07.0104 with the WSUS support and packager safety updates.
- Carries collection-manager 2026.10.07.0010 with connect-without-scan, open-by-ID, and large-site inventory improvements.
- Ships the other nine components unchanged.

## [2026.10.03.0046] - 2026-10-03

## 1 of 11 components refreshed

### Installer

- Carries site-hygiene 2026.10.03.0024, which finds supersedence and dependency relationships.
- Ships the other ten components unchanged.
## [2026.10.02.0045] - 2026-10-02

## 1 of 11 components refreshed

### Installer

- Carries app-packager 2026.10.02.0103 with the Anypoint Studio packager.
- Ships the other ten components unchanged.
## [2026.10.01.0044] - 2026-10-01

## 11 components, 1 added

### Installer

- Adds Pivots and Scripts 2026.10.01.0002.
- Ships the other ten components unchanged.
## [2026.10.01.0043] - 2026-10-01

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.10.01.0102 with the Options crash fix; the other eight components are unchanged.
## [2026.10.01.0042] - 2026-10-01

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.10.01.0101 with PyCharm 2026; the other eight components are unchanged.
## [2026.09.30.0041] - 2026-09-30

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.30.0100 with the multilingual Adobe Acrobat Reader; the other eight components are unchanged.
## [2026.09.30.0040] - 2026-09-30

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.30.0099 with the One Click plan, run and report; the other eight components are unchanged.
## [2026.09.30.0039] - 2026-09-30

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.30.0098; the other eight components are unchanged.
## [2026.09.30.0038] - 2026-09-30

## 3 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.30.0097 with WSUS publishing and three publish buttons.
- Carry site-hygiene 2026.09.29.0023 with the Live view read fixes.
- Carry deployment-helper 2026.09.29.0012 with the browse list and layout fixes.
- The other seven components are unchanged.
## [2026.09.27.0037] - 2026-09-27

## 1 of 10 components refreshed

### Installer

- Carry deployment-helper 2026.09.27.0011 with ring deployments; the other eight components are unchanged.

## [2026.09.25.0036] - 2026-09-25

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.25.0096; the other eight components are unchanged.

## [2026.09.25.0035] - 2026-09-25

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.25.0095; the other eight components are unchanged.

## [2026.09.25.0034] - 2026-09-25

## 1 of 10 components refreshed

### Installer

- Carry app-packager 2026.09.25.0094; the other eight components are unchanged.

## [2026.09.25.0033] - 2026-09-25

## Two components fold into Site Hygiene: 10 components ship instead of 12

### Installer

- Remove ConfigMgr Health Dashboard and Supersedence and Dependency Auditor; Site Hygiene carries their features.
- Zip each retired component's folder under site-hygiene\legacy on upgrade, then remove the folder.
- Keep a retired component's json files, history, logs, and reports under site-hygiene\legacy.
- Delete the retired components' Start Menu shortcuts on upgrade.
- Carry site-hygiene 2026.09.25.0020, deployment-helper 2026.09.25.0009, and app-packager 2026.09.25.0093.

### Launcher

- Drop the Health Dashboard tile.

### Tests

- Add an installer upgrade test that runs a fixture installer over a retired layout.

## [2026.09.21.0032] - 2026-09-21

### Fixed

- Use the launcher site code and provider in every tool that has none saved.

### Installer

- Carry new releases of all eleven components.

## [2026.09.21.0031] - 2026-09-21

### Changed

- Use the product name Configuration Manager in the launcher, the shared module and the README.
- Name the launcher window AppPackager Suite.
- Rename the Start Menu shortcut MECM Health Dashboard to ConfigMgr Health Dashboard.

### Installer

- Carry new releases of all eleven components; each one uses a date version.
- Leave each component's release procedure file out of the installer.

## [2026.09.18.0030] - 2026-09-18

### Changed

- Install the launcher to the app-packager-suite folder instead of suite-core.
- Move launcher settings and window state to the new folder on upgrade.

### Installer

- Ask to close running suite tools when the old launcher folder is in use.

## [2026.09.18.0029] - 2026-09-18

### Changed

- Rename the repository to app-packager-suite.
- Use date versions; the installer and the module share one version.
- Rename the module zip to AppPackagerSuite-<version>.zip.

### Installer

- Carry app-packager 2026.09.18.0090 and site-hygiene 2026.09.18.0014; the other ten components are unchanged.

## [0.5.5] - 2026-09-18

### Installer

- Carry app-packager 2026.09.18.0089; the other eleven components are unchanged.

## [0.5.4] - 2026-09-17

### Installer

- Carry app-packager 1.6.0.9; the other eleven components are unchanged.

## [0.5.3] - 2026-09-17

### Installer

- Carry app-packager 1.6.0.8; the other eleven components are unchanged.

## [0.5.2] - 2026-09-16

### Installer

- Carry app-packager 1.6.0.7; the other eleven components are unchanged.

## [0.5.1] - 2026-09-15

### Installer

- Carry app-packager 1.6.0.6; the other eleven components are unchanged.

## [0.5.0] - 2026-09-15

### Installer

- Carry app-packager 1.6.0.5; the other eleven components are unchanged.

## [0.4.18] - 2026-09-14

### Installer

- Carry app-packager 1.6.0.4; the other eleven components are unchanged.

## [0.4.17] - 2026-09-14

### Installer

- Carry app-packager 1.6.0.3; the other eleven components are unchanged.

## [0.4.16] - 2026-09-14

### Installer

- Carry app-packager 1.6.0.2; the other eleven components are unchanged.

## [0.4.15] - 2026-09-09

### Installer

- Carry app-packager 1.5.2.2 and installer-analysis 1.3.4.0; the other ten components are unchanged.

## [0.4.14] - 2026-09-09

### Installer

- Carry app-packager 1.5.2.1; the other eleven components are unchanged.

## [0.4.13] - 2026-09-07

### Installer

- Carry app-packager 1.5.2.0; the other eleven components are unchanged.

## [0.4.12] - 2026-09-05

### Installer

- Carry app-packager 1.5.1.9; the other eleven components are unchanged.

## [0.4.11] - 2026-09-04

### Installer

- Carry app-packager 1.5.1.8; the other eleven components are unchanged.

## [0.4.10] - 2026-09-04

### Installer

- Carry app-packager 1.5.1.7; the other eleven components are unchanged.

## [0.4.9] - 2026-09-04

### Installer

- Carry app-packager 1.5.1.6; the other eleven components are unchanged.

## [0.4.8] - 2026-09-04

### Installer

- Carry app-packager 1.5.1.5 and installer-analysis 1.3.3.0; the other ten components are unchanged.

## [0.4.7] - 2026-09-04

### Installer

- **Component refresh.** The suite installer carries app-packager 1.5.1.4
  (install mode toggle for switchable installers in the drop preview) and
  installer-analysis 1.3.2.0 (both install modes reported for NSIS and
  Inno Setup installers that accept a mode switch). The other ten
  components are unchanged from 0.4.6. Component versions and commits are
  in `suite-manifest.json` as before.

## [0.4.6] - 2026-09-04

### Build

- **Component release guard.** `build-suite-installer.ps1` refuses to
  build unless every component repository is clean, checked out at its
  highest `v*` tag, and that tag's version equals the version the payload
  carries; the tag must also exist on origin and have a GitHub release
  (`-SkipReleaseCheck` waives the two remote checks for an offline build).
  A component bumped but never released, or a stale checkout of one that
  was, stops the build with the component and the two versions named.
  `-ValidateOnly` runs the checks for all twelve components and stops
  before compiling.

### Installer

- **Component refresh.** The suite installer carries the same eleven
  tool versions as 0.4.5; only the launcher (this repository) changed.

## [0.4.5] - 2026-09-04

### Installer

- **Component refresh.** The suite installer carries app-packager 1.5.1.3
  (the Options window reports how GitHub API calls authenticate, and a
  signed-in GitHub CLI login is used for those calls). The other eleven
  components are unchanged from 0.4.4. Component versions and commits are
  in `suite-manifest.json` as before.

## [0.4.4] - 2026-09-04

### Installer

- **Component refresh.** The suite installer carries app-packager 1.5.1.2
  (Slack staged as the vendor's MSIX, Defraggler and ShareX following their
  vendors' source changes, Wireshark staged from its compiled installer
  script, GitHub API calls authenticated through `GITHUB_TOKEN`). The other
  eleven components are unchanged from 0.4.3. Component versions and
  commits are in `suite-manifest.json` as before.

## [0.4.3] - 2026-09-04

### SuiteCommon

- **`Repair-WindowsPowerShellModulePath`.** A Windows PowerShell process
  launched from PowerShell 7 inherits the 7.x module directories at the
  front of `PSModulePath`; every runspace opened later and every child
  `powershell.exe` then autoloads a `Microsoft.PowerShell.Utility` that
  carries no `Get-FileHash` or `ConvertFrom-Json` in 5.1. The module
  strips those roots and puts `$PSHOME\Modules` first at import time, so
  every tool that imports SuiteCommon is covered before it opens a
  runspace; `New-SuiteBgRunspace` repeats the repair before it creates
  the runspace.
- **Bootstrap failures throw.** `New-SuiteBgRunspace` disposes the
  runspace and rethrows when the module import inside it fails, instead
  of handing back a runspace whose later commands fail as unknown.

### Installer

- **Component refresh.** The suite installer carries app-packager
  1.5.1.1 (Inno Setup drops read from the compiled header, Apache
  NetBeans packager, the per-user misclassification of Inno Setup 6
  stubs fixed), installer-analysis 1.3.1.0 (Inno Setup header decoding
  for data versions 5.x through 7.0.0.3), site-hygiene 0.8.1,
  collection-and-compliance-manager 1.0.2, collection-manager 1.2.3,
  deployment-helper 1.2.3, detection-tester 1.2.3, dp-content-manager
  1.2.3, maintenance-window-manager 1.2.3, mecm-health-dashboard 1.3.3
  and supersedence-auditor 1.0.1; every component vendors SuiteCommon
  0.4.3 (supersedence-auditor carries the same repair inline), and the
  version labels of every tool read their entry script header.
  Component versions and commits are in `suite-manifest.json` as before.

## [0.4.2] - 2026-09-04

### Installer

- **Component refresh.** The suite installer carries app-packager
  1.5.1.0 (NSIS installers analyzed from their compiled script, per-user
  drops staged as user-context deployments, PowerShell 7 module-path
  isolation, window sizing) and installer-analysis 1.3.0.1 (NSIS header
  decoding, analysis runspace module-path fix). Component versions and
  commits are in `suite-manifest.json` as before.

### Build

- **Entry-header drift guard.** `Get-ComponentVersion` warns when a
  component's entry script `Version` header disagrees with its version
  of record, so a stale header cannot ship inside the payload unnoticed.

## [0.4.1] - 2026-09-02

Supersedes the unreleased 0.4.0 entry, whose installer carried three
components; the shipping installer carries twelve.

### Installer

- **`installer\suite.nsi`** - all-in-one NSIS installer for all twelve
  suite components: the launcher (`suite-core\`), `app-packager\`,
  `site-hygiene\`, `collection-and-compliance-manager\`,
  `collection-manager\`, `deployment-helper\`, `detection-tester\`,
  `dp-content-manager\`, `installer-analysis\`,
  `maintenance-window-manager\`, `mecm-health-dashboard\` and
  `supersedence-auditor\`. `RequestExecutionLevel user`, no elevation,
  install root `%LOCALAPPDATA%\AppPackagerSuite` with one subfolder per
  component. Start-menu group "AppPackager Suite" carries twelve
  shortcuts, each targeting the native `System32` `powershell.exe` with
  `-NoProfile -ExecutionPolicy Bypass -File <entry>.ps1`. HKCU ARP entry
  (`DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`,
  `UninstallString`, `QuietUninstallString`, `EstimatedSize`, `NoModify`,
  `NoRepair`). `/S` silent install and uninstall.
- **Upgrade preserves user state without a backup-restore cycle.** Payload
  files overwrite; files absent from the payload are untouched, and every
  preserved class (`*.json` per app folder and its `Packagers` subfolder,
  `Logs\`, `Packagers\Icons\`) is absent from the payload because each is
  gitignored in its source repository. Same preserve set as
  app-packager's `install.ps1` `Get-PreservedStateFile`, reached without
  copying state out and back.

### Build

- **`tools\build-suite-installer.ps1`** - stages the payload from the
  local sibling repositories at HEAD via `git archive`, strips `Tests`
  folders and `*.Tests.ps1` from the payload, reads each component
  version, writes `suite-manifest.json` (suite version, plus
  name/version/versionSource/commit/entry/shortcut/file-count per
  component), compiles with `makensis`, and emits
  `SuiteSetup-<version>.exe` and `checksums.txt` into `installer\out\`.
  Suite version defaults to `yyyy.MM.dd`; `-SuiteVersion` overrides.
- **One component table drives the whole build.** `$Components` carries
  folder, repository, entry script, shortcut name and version source per
  row; staging, the manifest, and the generated `components.nsh` that
  `suite.nsi` includes all read it, so adding a tool is one row rather
  than edits in three places. `suite.nsi` names no component.
- **Version source is per component and recorded in the manifest.**
  `ScriptHeader` for app-packager, `ModuleManifest` for suite-core,
  `Changelog` for the other ten - the header `Version` line in the tool
  repositories trails their CHANGELOG headline.

### Changed

- **Uninstall preserves user state.** The uninstaller deletes only the
  files the build shipped (a generated per-file list), removes
  directories non-recursively, and leaves preferences, logs, icons, and
  anything else written after install in place.

## [0.3.2] - 2026-09-01

### Fixed

- **Launcher** - maximized-window restore and background bootstrap
  errors surfaced instead of swallowed. (Entry backfilled; the release
  shipped without one.)

## [0.3.1] - 2026-08-16

### Added

- **`Connect-CMSite` regains the site-code mismatch diagnostic** for
  every consumer: under verbose logging, a drive whose provider serves
  different site codes is called out with the "Key cannot be null"
  explanation instead of leaving later CM cmdlets to fail opaquely.

## [0.3.0] - 2026-08-16

### Additions

- **Suite launcher (`start-suite.ps1`).** Thin WPF shell: one tile per
  installed suite tool (discovered as sibling folders, version read from
  each tool's CHANGELOG with a manifest fallback), each launching as its
  own process. The connection profile (site code + SMS provider) is
  entered once and handed to every launch via `SUITE_CM_PROVIDER` /
  `SUITE_CM_SITECODE`; `Connect-CMSite` already falls back to the
  provider variable. MahApps assemblies vendored under `Lib\`.
- **Background-work helpers.** `New-SuiteBgRunspace` (STA runspace with
  tool-module pre-import and attached logging), `Stop-SuiteBgWork`
  (`BeginStop` into a reaped graveyard instead of a synchronous `Stop()`
  that blocks the UI thread while a pipeline is stuck inside a provider
  call), `Close-SuiteBgRunspace` (`CloseAsync` at shell exit).
  Explicit-argument by design: shells keep their own pipeline state.
- **CM collection widgets.** `Build-CollectionTree` (folder-nested,
  filterable) and `Show-CollectionPickerDialog` (modal picker over the
  tree). The tree builder fixes a latent defect in the consumers'
  originals: the populate scriptblock's boolean no longer leaks into the
  pipeline ahead of the returned leaf count.

## [0.2.0] - 2026-08-16

### Additions

- **Window chrome.** Native title-bar drag (`Install-TitleBarDragFallback`
  and the WM_NCHITTEST hook family) with hook state owned by the module,
  and window-state persistence (`Save-WindowState` /
  `Restore-WindowState`) with a clamp-to-nearest-monitor restore and a
  `RestoreBounds`-aware save.
- **Theming.** `Initialize-SuiteTheme` stores the per-shell context
  (standard palette with overrides, view buttons, dark/active-view
  getters); `Update-TitleBarBrushes`, `Update-SidebarButtonTheme`
  (fill- and border-based active modes), `Set-ButtonTheme`, and
  `Set-DialogTheme` read it.
- **Themed dialogs.** `Show-ThemedMessage` (OK / OKCancel / YesNo,
  glyph-only icons, Escape closes OK-only dialogs) and
  `Show-ConfirmDialog`, both themed from their owner window.

### Fixed

- **Hook-state leak on window close.** Removal keyed on the HWND, which
  is already destroyed when `Closed` fires, so the delegate and window
  reference of every hooked window stayed rooted for the process
  lifetime; removal now sweeps by window reference.
- **Never-shown windows crashed the save path.** Non-finite geometry
  (NaN / Empty rect) skips the save instead of throwing from the
  caller's `Closing` handler.

## [0.1.0] - 2026-08-14

### Additions

- **`SuiteCommon` module, first release.** Logging (`Initialize-Logging`
  with `-Attach` and `-VerboseLogging`, four-level `Write-Log` with
  `SUITE_VERBOSE` gating for DEBUG, `Write-LogErrorRecord` full-diagnostic
  catch-block logging), CM site connection (`Connect-CMSite` with
  globally scoped PSDrive creation, stale-drive rebuild, multi-path
  console module resolution, optional `Get-CMSite` verification;
  `Disconnect-CMSite`; `Test-CMConnection`; `Get-CMConnectionInfo`;
  `Test-CMSiteCodeMatchesProvider` mismatch diagnostic), flat JSON
  settings persistence (`Read-SuiteSettings`, `Save-SuiteSettings`), and
  `Get-SuiteCommonVersion`.
- **`sync-suitecommon.ps1`.** Vendors the module into consumer repos at
  `Lib\SuiteCommon\`; `-Check` reports content-hash drift and exits
  nonzero so it can gate releases.
