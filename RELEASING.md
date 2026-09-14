# Releasing suite-core

A suite-core release ships two assets built from twelve repositories: the signed `SuiteSetup-<yyyy.MM.dd.N>.exe` installer and the `SuiteCore-<version>.zip` module zip, plus `checksums.txt`. The installer is built and signed by `.github/workflows/release.yml`. Never publish an installer built on a workstation: it is unsigned.

This file is excluded from the module zip and the installer payload is built from the release tag.

## 1. Every component must already be released

The installer carries eleven component repositories plus suite-core. For each component, the latest GitHub release must be the commit you want to ship. The build refuses anything else.

Release a component first (its own procedure, for example `app-packager/RELEASING.md`) when it has commits or changes that belong in the suite.

Local check, from `C:\projects\suite-core`:

```powershell
.\tools\build-suite-installer.ps1 -ValidateOnly
```

| Build error | Meaning | Fix |
|---|---|---|
| `working tree has N uncommitted change(s)` | A component checkout is dirty. | Commit and release the change, or `git stash` it for the local check and `git stash pop` afterwards. The workflow builds from clean clones and is not affected. |
| `HEAD (...) is not the vX commit ...; N commit(s) past the tag would ship unreleased` | A component has commits after its latest tag. | Release that component, or check out its tag locally. The workflow uses the release tag and is not affected, but the commits will not ship. |
| `payload carries version X but the latest release tag is vY` | The version in the component does not match its tag. | Fix the version in that component and release it. |
| `tag vX is not on origin` / `has no GitHub release` | The component tag was never pushed or released. | Push the tag and publish the component release. |

## 2. Bump suite-core

1. `SuiteCommon/SuiteCommon.psd1`: raise `ModuleVersion` by 0.0.1.
2. `CHANGELOG.md`: add the entry at the top. Shape used for component refreshes:

```
## [0.4.17] - 2026-09-14

### Installer

- Carry app-packager 1.6.0.3; the other eleven components are unchanged.
```

3. Run the tests: `Invoke-Pester -Path Tests` under Windows PowerShell with Pester 5. Any failure stops the release.
4. Commit as `Release <version>: <summary>`, then tag and push:

```bash
git tag -a v<version> -m v<version>
git push origin main v<version>
```

## 3. Run the signed build

Pick the installer version: the date as `yyyy.MM.dd` plus `.N`, where N is one more than the highest N already published for that date (`gh release list -R jasonulbright/suite-core`).

```bash
gh workflow run release.yml -R jasonulbright/suite-core --ref main \
  -f tag=v<version> -f suite_version=<yyyy.MM.dd.N> -f headline="<N> of 12 components refreshed"
gh run watch -R jasonulbright/suite-core $(gh run list -R jasonulbright/suite-core --workflow release.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

The workflow:

1. Checks the tag equals `ModuleVersion`.
2. Clones each component at its latest GitHub release beside suite-core.
3. Installs NSIS and runs `tools/build-suite-installer.ps1 -SuiteVersion <N> -AllowUnpublished suite-core`.
4. Builds `SuiteCore-<version>.zip` with `git archive`, excluding `Tests`, `*.Tests.ps1`, `.github` and this file.
5. Signs the installer with Azure Artifact Signing (`signalridgelabs` / `SRL-Public`) through the `release` environment's federated credential, then verifies the signature is valid, from `CN=Jason Ulbright`, and timestamped.
6. Writes `checksums.txt` (`<sha256>  <name>`, two spaces) and creates a **draft** release titled with the tag, notes = headline + changelog entry + `Full changelog: CHANGELOG.md`.

The `release` environment holds `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`. The Entra app's federated credential `suite-core-release-signer` trusts `repo:jasonulbright/suite-core:environment:release`.

## 4. Verify, then publish

```bash
mkdir -p verify && cd verify
gh release download v<version> -R jasonulbright/suite-core --clobber
sha256sum -c checksums.txt
powershell -NoProfile -Command "Get-AuthenticodeSignature .\SuiteSetup-<N>.exe | Format-List Status, SignerCertificate, TimeStamperCertificate"
gh release edit v<version> -R jasonulbright/suite-core --draft=false --latest
```

Publish only when both checksums report OK and the signature status is `Valid`.

## 5. If a release is wrong

Delete the release and the tag, fix the cause, and run the procedure again with the same version:

```bash
gh release delete v<version> -R jasonulbright/suite-core --yes
git push origin :refs/tags/v<version>
git tag -d v<version>
```
