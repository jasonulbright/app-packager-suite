# Site data contract

Status: contract schemaVersion 1. The suite launcher and the suite tools read and write these locations (Q-112f, last section). APD and the PowerShell app follow in Q-112d and Q-112g. This page defines the layout so that App Packager Desktop (APD), the PowerShell app and the suite tools use one layout. The migration (Q-112c, section Migration below) copies old data into them.

## Files of the contract

| File | Content |
|---|---|
| `docs/schema/site.schema.json` | Schema of `sites\<SITE>\site.json`. |
| `docs/schema/active-site.schema.json` | Schema of `active-site.json`. |
| `docs/schema/scope-manifest.schema.json` | Schema of the scope manifest. |
| `Tests/Fixtures/SiteData/scope-manifest.json` | The scope manifest: each store is site, global or secret. |
| `Tests/Fixtures/SiteData/site-cases.json` | Test cases for site codes, folder names, tool names and relative paths. |
| `Tests/Fixtures/SiteData/site.json`, `active-site.json` | Example files. |

The same files are in the APD repository (all in `tests/ApplicationPackagerEngine.Tests/Fixtures/SiteData`). Both repositories pin the SHA-256 of every file (line endings normalized to LF). A change in one copy fails the test of the other repository until both change. A change of a file is a contract change. Raise `schemaVersion` when a reader of the old version would misread the new file.

Code: `Get-SuiteDataRoot`, `Get-SuiteSiteFolder`, `Get-SuiteActiveSite`, `Test-SuiteSiteCode`, `Test-SuiteSiteName`, `ConvertFrom-SuiteSiteFolderName` and `Get-SuiteFreeSiteFolderName` in `SuiteCommon`. The C# twin is `SiteDataPaths` in `ApplicationPackagerEngine/Services`. Both read the same cases.

## Data root

| Case | Data root |
|---|---|
| Default | `%LOCALAPPDATA%\AppPackagerData` |
| `APP_PACKAGER_DATA_ROOT` set | `<value>\Users\<Windows SID>` (a value that already ends in `Users\<SID>` is kept) |

Rules:

- The data root is outside every install folder.
- It cannot be under Program Files.
- The code that builds a path never creates a folder. The first writer creates it.

## Layout

```
<DATA ROOT>\
  active-site.json
  sites\
    <SITE>\                 for example AB1 or AB1~2
      site.json
      settings.json         site-scoped settings only
      state\app-state.json
      results\
      deployments\
      hygiene\
      dpcontent\
      pivots\sessions\
      maintenance\
      collections\
      handoff\ring-plan.json
      tools\<tool>\         site-scoped prefs and data of a suite tool
      imported-from.json
      migration.json        marker of the migration (Q-112c)
```

Global data stays where it is today. The migration moves no global file.

## Site code and folder name

- A site code is three characters, A-Z or 0-9. Lower case input is accepted and written in upper case.
- These codes are refused, because ConfigMgr and Windows reserve them as folder names: `AUX`, `CON`, `ENV`, `NUL`, `PRN`, `SMS`. Source: Microsoft Learn, "Prepare to install Configuration Manager sites".
- A space, a dot, a slash or any other character is refused. There is no trimming: `" AB1"` is invalid.
- The folder name is the site code in upper case.
- A site code that a second environment reuses gets the folder name `<CODE>~2`, then `<CODE>~3`, and so on. The number is 2 or more with no leading zero. `Get-SuiteFreeSiteFolderName` returns the first free name and compares without regard to case.
- Inside a file, `siteCode` in `site.json` is the three-character code. The folder name is the only place that carries `~N`. `active-site.json` holds the folder name.
- The tool name and an area name are lower case letters, digits and hyphens. They start with a letter or a digit. `-Tool` and `-Area` are exclusive. An area can have several segments separated by `\`.

## site.json

| Field | Type | Content |
|---|---|---|
| `schemaVersion` | number | `1` |
| `siteCode` | string | Three characters, upper case. |
| `label` | string, optional | Free text for the switcher. |
| `providers` | array of string | SMS Provider FQDNs. The first is the default. The list can be empty. |
| `createdUtc`, `lastUsedUtc` | string | UTC, `yyyy-MM-ddTHH:mm:ssZ`. |
| `migratedFrom` | string, optional | `legacy-single-site` when the migration made the folder. |

## active-site.json

| Field | Type | Content |
|---|---|---|
| `schemaVersion` | number | `1` |
| `siteCode` | string | The folder name, for example `AB1` or `AB1~2`. |
| `changedUtc` | string | UTC time of the last switch. |

Order of choice at start: `SUITE_CM_SITECODE`, then `APP_PACKAGER_SITE`, then `active-site.json`, then first-run setup. A value that is not a valid folder name is skipped. A file with another `schemaVersion` or bad JSON is ignored.

## Scope manifest

`scope-manifest.json` lists every store. Each entry has these fields:

| Field | Content |
|---|---|
| `id` | A unique key, for example `apd.deployments`. |
| `app` | `apd`, `powershell`, `suite-launcher`, `suite`, or a tool name. |
| `kind` | `setting`, `file`, `folder` or `table`. |
| `location` | Where the store is today. |
| `key` | The setting key or the file or folder name. |
| `scope` | `site`, `global` or `secret`. |
| `import` | `on` (copied by default on import), `off` (copied only if the user selects it) or `never`. |
| `target` | A path below `sites\<SITE>\` for a site entry. `null` for a global or secret entry. |

Rules that the tests check:

- A secret has `import` `never` and no target.
- A site entry has a target. A global entry has none.
- A store that mixes both scopes appears as one entry for each scope.
- Identity (site code, provider), results, run data, audit logs and sessions of a site are never imported.

## Rules for secrets

- A secret is never stored in a site folder.
- A secret is never copied between sites and never exported. The import action excludes each secret by the entry in the manifest, and the user enters the secret again.
- The secrets are the GitHub token, the Intune client secret, the NVD key, the feed credentials, the webhook URL and the TeamViewer `ApiToken`.
- A secret stays global (DPAPI for the current Windows user) or belongs to a tenant. The Intune tenant is independent of the site.

## Names, not IDs

An import copies names (DP group, test collection, update waves, ring plan collection names). It never copies a site-assigned ID (collection ID, package ID, object ID). After the next connect, the app lists each name that the target site does not have and clears nothing.

## Migration of single-site data (Q-112c)

Code: `Invoke-SuiteSiteMigration` and `Format-SuiteSiteMigrationReport` in `SuiteCommon` (the PowerShell app and the suite tools). The C# twin is `SiteDataMigration` in `ApplicationPackagerEngine/Services` (APD). A function call starts each of them. No start-up code calls them. No store reads the new paths before Q-112d.

Rules:

- Copy, never move. The old files stay in place and keep their content for at least one release. A later cleanup is a separate step with the owner's approval.
- A copy counts only when its SHA-256 equals the source. A copy that does not match stops the run. The old files stay in use.
- Site items go to `sites\<SITE>\` for the site code that is configured now. Global items stay where they are. A secret is never copied. The copy of a settings file keeps only the keys that the scope manifest lists, and it drops any property whose name contains token, secret, password, apikey, credential, protected or webhook.
- A source that names another site (its own `SiteCode` differs) is not copied into this site folder. The report says so. A run with `-SiteCode` for that site copies it.
- No site code is configured (APD: `SiteCodeSaved` is not true, or the code is invalid; suite: no code in `suite.settings.json` or `AppPackager.preferences.json`, and none given): nothing is migrated, nothing is created, and the report says why.
- Idempotent. A second run changes nothing and reports `NothingChanged`.
- Resumable. A copy goes to `<file>.migrating`, is checked, then renamed. A crash leaves no partial file at the destination. `migration.json` is the journal: it lists each copied file with its source and SHA-256, is written after each copy, and changes only when its list changes. Both apps write the same marker and keep each other's entries.
- A destination with other content is kept and reported (`Conflict`). `SourceChanged` means the destination is what an earlier run of the same source wrote, and the source changed since. Neither status writes anything.
- A JSON file that two apps share (`settings.json`, `statepp-state.json`) is merged by top-level key: a key that is absent is added, an equal key is accepted, a different value is a conflict and nothing is written.
- Two apps that write the same results file (`results\CheckConfigMgrResult.csv` from APD and from the PowerShell app) conflict when the content differs. The first copy stays. Q-112d decides how the two share it.
- A dry run (`Plan` in C#, `-DryRun` in PowerShell) lists each item with scope, source, destination, SHA-256 and status. It writes nothing and creates no folder.
- `history.db` of APD is copied as a whole file and is blocked while a `-wal` or `-journal` file is not empty. The split of its rows by site is part of Q-112d.

Statuses: `Planned`, `Copied`, `AlreadyDone`, `Conflict`, `SourceChanged`, `NotPresent`, `GlobalStays`, `SecretNotCopied`, `Blocked`, `Failed`.

Tests: `Tests/SiteData.Migration.Tests.ps1` and `SiteDataMigrationTests` in APD seed an old-layout profile in a temp folder and compare the SHA-256 of every old file before and after a run, a second run, a crash after each item and a crash in the middle of a copy.

## The launcher and the suite tools (Q-112f)

Code: `Get-SuiteSiteList`, `Set-SuiteSiteIdentity`, `Set-SuiteActiveSite`, `Resolve-SuiteToolSite`, `Resolve-SuiteToolPath`, `Read-SuiteToolPrefs`, `Save-SuiteToolPrefs`, `Set-SuiteFooterNote` and `Start-SuiteSiteWatch` in `SuiteCommon`. The launcher (`start-suite.ps1`) and each tool call them.

Rules:

- The launcher shows the active site in the Site box, with the known sites in the list, and a new three-character code can be typed. Save writes `site.json` (the provider moves to the front of `providers`), `active-site.json` and `SiteCode` and `SMSProvider` in the site's `settings.json`. It also sets `SUITE_CM_SITECODE` (the three-character code, left out for a reused code such as `AB1~2`), `APP_PACKAGER_SITE` (the folder name) and `SUITE_CM_PROVIDER` for the tools it starts. The old `SiteCode` and `SMSProvider` in `suite.settings.json` stay as they are for one release. They are read only when no site is chosen.
- A tool calls `Resolve-SuiteToolSite` once at start. The order of choice is the one above, with the `SiteCode` of the tool's own old prefs file as the last source. With no site the result is not active and the tool keeps its old paths.
- With a site, the first start of the tool for that site copies the tool's old site data into `sites\<SITE>\tools\<tool>` (`Invoke-SuiteSiteMigration -Tool <tool>`: copy, SHA-256 check, old files kept) and writes `tools\<tool>\migrated.json`. A later start skips the copy. A site folder with `~N` gets no copy. A tool whose old prefs name another site gets no copy of any file.
- Site prefs: `Read-SuiteToolPrefs` takes the site keys from `tools\<tool>\prefs.json` (a key the file lacks takes the default, so one site never shows the values of another) and the other keys from the old prefs file. `Save-SuiteToolPrefs` writes the site keys to the site file, the other keys to the old file, and moves a changed provider to the front of `providers`. A tool never changes the site code. The site is chosen in the launcher.
- Stores: `Resolve-SuiteToolPath -Site $site -Name <store> -LegacyPath <old path>` returns the path below `tools\<tool>` for a site, and the old path with no site. No tool stores an absolute default path in its prefs.
- A tool keeps the site it started with. `Start-SuiteSiteWatch` reads `active-site.json` (never the environment) every 5 seconds while the window is open. When the launcher chose another site, the footer shows a note: "The launcher now uses site CD2. This window keeps site AB1 until you restart it."

Store names below `sites\<SITE>\tools\<tool>\` (these are the names that the migration writes):

| Tool | Site prefs keys in `prefs.json` | Other stores |
|---|---|---|
| `site-hygiene` | `SiteCode`, `SMSProvider`, `SQLServer` | `lastscan.json`, `suppressions.json`, `history\`, `reports\` |
| `deployment-helper` | `SiteCode`, `SMSProvider` | `deployment-audit.jsonl`, `rings\` (with `rings\runs\`), `rollouts\` |
| `update-planner` | `SiteCode`, `SMSProvider`, `Waves` | `update-planner-actions.jsonl`, `reports\` |
| `device-inspector` | `SiteCode`, `SMSProvider`, `LastDevice` | `DeviceInspector-actions.log`, `reports\` |
| `collection-manager`, `collection-and-compliance-manager`, `maintenance-window-manager`, `dp-content-manager` | `SiteCode`, `SMSProvider` | `reports\` |
| `pivots-and-scripts` | `SiteCode`, `SMSProvider` | `sessions\` |
| `detection-tester`, `installer-analysis` | none | none (their prefs and reports are global) |

Tests: `Tests/SiteTools.Tests.ps1` (site list, per-tool migration, prefs split, paths, launcher helpers, two-site isolation).
