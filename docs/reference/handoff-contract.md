# Handoff contract

Status: contract schemaVersion 1. A handoff file carries data from one suite tool to another with no hand copying. Update Planner writes its plan (H-1). Deployment Helper reads it. The same page sets the rules for the age and the source of the data that a consumer shows (G-7).

## Location

One file for each site and kind, in the handoff folder of the site folder of the [site data contract](site-data-contract.md):

```
<DATA ROOT>\sites\<SITE>\handoff\<kind>.json
```

For example `%LOCALAPPDATA%\AppPackagerData\sites\AB1\handoff\ring-plan.json`. The folder name is the site folder name (`AB1` or `AB1~2`). The data root follows `APP_PACKAGER_DATA_ROOT` as the site data contract says.

- The file belongs to the site. A plan for AB1 never lands in the folder of CD2, so a tool that works on one site never offers the plan of another site.
- One file for each kind. Each run overwrites it. There is no history.
- The code that builds the path never creates a folder. The producer creates it when it writes.
- Why not a folder beside the script: a tool folder differs by tool and a user can move it. Why not a global folder: the data depends on a site.

Code: `Get-SuiteHandoffPath`, `Write-SuiteHandoff`, `Read-SuiteHandoff`, `ConvertTo-SuiteStaleHours`, `Format-SuiteAge` and `Get-SuiteDataAge` in `SuiteCommon`.

## Header

Every handoff file is a JSON object in UTF-8 with no byte order mark. These header fields are at the top level. The reader finds each name without regard to case.

| Field | Content |
|---|---|
| `SchemaVersion` (or `schemaVersion`) | Integer, 1 or more. A reader refuses a version above the one it knows. A reader ignores a field it does not know. |
| `Format` (or `kind`) | Text. The kind of the file. For the ring plan: `SuiteRingPlan`. |
| `Producer` (or `producer`) | Object: `Name` (the tool) and `Version` (the tool version). |
| `CreatedUtc` (or `createdUtc`) | `yyyy-MM-ddTHH:mm:ssZ`, the time of the write. |
| `Site` (or `site`) | Object: `SiteCode`, the three-character code. No host name and no credential. |

The ring plan keeps its own fields (`Format`, `SchemaVersion`, `Name`, `Rings` and the others). The new fields `Producer`, `CreatedUtc` and `Site` are extra, and Deployment Helper v2026.11.22.0031 and older ignore them. The files `docs/schema/ring-plan.schema.json` and `Tests/Fixtures/shared-ring-plan.json` of Update Planner and Deployment Helper do not change, so their SHA-256 pins stay.

## Content limits

- No password, token, key, credential or webhook. The writer refuses text that has a property whose name holds `token`, `secret`, `password`, `apikey`, `credential` or `webhook`.
- Names, versions, ids and dates only. No application payload and no path of the user.

## Write

The writer saves the text to a temp file in the same folder and swaps it in. A crash or a full disk leaves the old file whole. The write never throws: it returns `Ok`, `Path` and `Message`.

## Consumer rules

1. Show the producer, its version, the site code and the age where the data loads. The age is text such as "2 days old".
2. Show a stale mark when the file is older than the limit of the user. The limit is a setting in hours or days. A stale file is flagged and still usable.
3. Load the data into a preview. A load never acts. Deploy keeps its own validation and confirm.
4. Refuse a file whose `SchemaVersion` is above the known one, whose kind is not the expected one, that is not a JSON object, or that has no valid `CreatedUtc`. The refusal names the file and the versions, and the log keeps the same text.
5. Flag a file for another site than the site of the tool (`SiteMismatch`).
6. One producer and one consumer for each kind. No tool lists the folder to find any file.

Statuses of `Read-SuiteHandoff`: `Ok`, `Missing`, `Unreadable`, `Malformed`, `WrongKind`, `TooNew` and `NoDate`.

## Kinds

| Kind | File | Producer | Consumer |
|---|---|---|---|
| `SuiteRingPlan` | `handoff\ring-plan.json` | Update Planner (the **Send to Deployment Helper** button) | Deployment Helper (Rings view) |

The Check ConfigMgr result is not a handoff file. It stays `results\CheckConfigMgrResult.csv` and `.json` of the site (version 0, no header). Deployment Helper shows the source, the site and the age of the rows from the `Source` and `CheckedAtUtc` columns of the file.

Tests: `Tests/SuiteCommon.Handoff.Tests.ps1`.
