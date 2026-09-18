# Releasing AppPackager Suite

A release ships two assets built from twelve repositories: the signed `SuiteSetup-<version>.exe` installer and the `AppPackagerSuite-<version>.zip` module zip, plus `checksums.txt`. The installer is built and signed by `.github/workflows/release.yml`. Never publish an installer built on a workstation: it is unsigned.

This file is excluded from the module zip and the installer payload is built from the release tag.

## 1. Every component must already be released

The installer carries eleven component repositories plus this repository. For each component, the latest GitHub release must be the commit you want to ship. The build refuses anything else.

Release a component first (its own procedure, for example `app-packager/RELEASING.md`) when it has commits or changes that belong in the suite.

Local check, from `C:\projects\app-packager-suite`:

```powershell
.\tools\build-suite-installer.ps1 -ValidateOnly
```

| Build error | Meaning | Fix |
|---|---|---|
| `working tree has N uncommitted change(s)` | A component checkout is dirty. | Commit and release the change, or `git stash` it for the local check and `git stash pop` afterwards. The workflow builds from clean clones and is not affected. |
| `HEAD (...) is not the vX commit ...; N commit(s) past the tag would ship unreleased` | A component has commits after its latest tag. | Release that component, or check out its tag locally. The workflow uses the release tag and is not affected, but the commits will not ship. |
| `payload carries version X but the latest release tag is vY` | The version in the component does not match its tag. | Fix the version in that component and release it. |
| `tag vX is not on origin` / `has no GitHub release` | The component tag was never pushed or released. | Push the tag and publish the component release. |

## 2. Set the version

The version is `YYYY.MM.DD.BBBB`: the release date, then a four-digit, zero-padded build number that increases by 1 per release and never resets. The same version is the tag, `ModuleVersion`, the installer version and the zip version. Keep the zero-padded text everywhere; `[version]` drops the leading zeros.

1. `SuiteCommon/SuiteCommon.psd1`: set `ModuleVersion` to the new version.
2. `CHANGELOG.md`: add the entry at the top. Shape used for component refreshes:

```
## [2026.09.18.0029] - 2026-09-18

### Installer

- Carry app-packager 2026.09.18.0090; the other eleven components are unchanged.
```

3. Run the tests: `Invoke-Pester -Path Tests` under Windows PowerShell with Pester 5. Any failure stops the release.
4. Commit as `Release <version>: <summary>`, then tag and push:

```bash
git tag -a v<version> -m v<version>
git push origin main v<version>
```

## 3. Run the signed build

```bash
gh workflow run release.yml -R jasonulbright/app-packager-suite --ref main \
  -f tag=v<version> -f headline="<N> of 12 components refreshed"
gh run watch -R jasonulbright/app-packager-suite $(gh run list -R jasonulbright/app-packager-suite --workflow release.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

The workflow:

1. Checks the tag is `vYYYY.MM.DD.BBBB` and equals `ModuleVersion`.
2. Clones each component at its latest GitHub release beside this repository.
3. Installs NSIS and runs `tools/build-suite-installer.ps1 -SuiteVersion <version> -AllowUnpublished app-packager-suite`.
4. Builds `AppPackagerSuite-<version>.zip` with `git archive`, excluding `Tests`, `*.Tests.ps1`, `.github` and this file.
5. Signs the installer with Azure Artifact Signing (`signalridgelabs` / `SRL-Public`) through the `release` environment's federated credential, then verifies the signature is valid, from `CN=Jason Ulbright`, and timestamped.
6. Writes `checksums.txt` (`<sha256>  <name>`, two spaces) and creates a **draft** release titled with the tag, notes = headline + changelog entry + `Full changelog: CHANGELOG.md`.

The `release` environment holds `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`. The Entra app's federated credential must trust the subject GitHub sends for this repository:

```
repo:jasonulbright@263023789/app-packager-suite@1334079327:environment:release
```

This repository sends GitHub's ID-based subject (`use_immutable_subject: true`). The subject carries the repository name, so a rename changes it; the repository ID does not change. A credential holding any other subject fails the Azure login with `AADSTS700213: No matching federated identity record found`. Read the subject GitHub sends with:

```bash
gh api repos/jasonulbright/app-packager-suite/actions/oidc/customization/sub
```

The credential subject is `<sub_claim_prefix>:environment:release`.

After the credential is fixed, re-run only the failed jobs; the build artifact is kept for 7 days:

```bash
gh run rerun <run id> -R jasonulbright/app-packager-suite --failed
```

## 4. Verify, then publish

```bash
mkdir -p verify && cd verify
gh release download v<version> -R jasonulbright/app-packager-suite --clobber
sha256sum -c checksums.txt
powershell -NoProfile -Command "Get-AuthenticodeSignature .\SuiteSetup-<version>.exe | Format-List Status, SignerCertificate, TimeStamperCertificate"
gh release edit v<version> -R jasonulbright/app-packager-suite --draft=false --latest
```

Publish only when both checksums report OK and the signature status is `Valid`.

## 5. If a release is wrong

Delete the release and the tag, fix the cause, and run the procedure again with the same version:

```bash
gh release delete v<version> -R jasonulbright/app-packager-suite --yes
git push origin :refs/tags/v<version>
git tag -d v<version>
```
