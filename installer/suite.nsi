; AppPackager Suite all-in-one installer.
; Per-user by design: no elevation, install root under %LOCALAPPDATA%, ARP in HKCU.
; Requires SUITEVERSION, PAYLOADDIR and OUTFILE on the makensis command line.

!ifndef SUITEVERSION
  !error "SUITEVERSION is required (makensis /DSUITEVERSION=...)"
!endif
!ifndef PAYLOADDIR
  !error "PAYLOADDIR is required (makensis /DPAYLOADDIR=...)"
!endif
!ifndef OUTFILE
  !error "OUTFILE is required (makensis /DOUTFILE=...)"
!endif

; SUITE_NAME and SUITE_KEY are overridable so the upgrade test can install a
; fixture under its own Start Menu folder and ARP key.
!ifndef SUITE_NAME
  !define SUITE_NAME  "AppPackager Suite"
!endif
!ifndef SUITE_KEY
  !define SUITE_KEY   "AppPackagerSuite"
!endif
!define SUITE_PUB     "Jason Ulbright"
!define ARP_ROOT      "Software\Microsoft\Windows\CurrentVersion\Uninstall\${SUITE_KEY}"
!define PS_ARGS_PRE   "-NoProfile -ExecutionPolicy Bypass -File"
; Folder of this script: components.nsh names helper files that ship beside it.
!define INSTALLERSRC  "${__FILEDIR__}"

Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel user
ManifestDPIAware true

Name "${SUITE_NAME}"
Caption "${SUITE_NAME} ${SUITEVERSION}"
BrandingText "${SUITE_NAME} ${SUITEVERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\${SUITE_KEY}"
InstallDirRegKey HKCU "${ARP_ROOT}" "InstallLocation"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "0.0.0.0"
VIAddVersionKey "ProductName"     "${SUITE_NAME}"
VIAddVersionKey "ProductVersion"  "${SUITEVERSION}"
VIAddVersionKey "FileVersion"     "${SUITEVERSION}"
VIAddVersionKey "FileDescription" "${SUITE_NAME} installer"
VIAddVersionKey "CompanyName"     "${SUITE_PUB}"
VIAddVersionKey "LegalCopyright"  "MIT"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"

; The suite icon: the setup and uninstall executables and, through
; components.nsh, the launcher shortcut.
!define MUI_ICON   "${PAYLOADDIR}\app-packager-suite\assets\apppackager-suite.ico"
!define MUI_UNICON "${PAYLOADDIR}\app-packager-suite\assets\apppackager-suite.ico"

; Per-component File, shortcut and shortcut-delete lines, generated into the
; payload directory by tools\build-suite-installer.ps1 from its component table.
!include "${PAYLOADDIR}\components.nsh"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
; A custom page asks whether to delete the user data. Silent uninstall skips it,
; so /S never deletes data. It comes before the confirm page, so the button that
; starts the uninstall is the last choice.
UninstPage custom un.DataPageShow un.DataPageLeave
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var PSExe
Var StartMenuDir
Var RemoveData
Var RemoveCheck

Function .onInit
  ; 32-bit installer on 64-bit Windows: $SYSDIR redirects to SysWOW64, whose
  ; powershell.exe would run the tools 32-bit. Resolve the native host instead.
  StrCpy $PSExe "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PSExe" +2 0
    StrCpy $PSExe "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  StrCpy $StartMenuDir "$SMPROGRAMS\${SUITE_NAME}"
FunctionEnd

; Shipped files are overwritten; files absent from the payload are left in place,
; which is what keeps user state (*.json, Logs\, Packagers\Icons\) across upgrades.
SetOverwrite on

Section "Suite" SecSuite
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "${PAYLOADDIR}\suite-manifest.json"

  !insertmacro SUITE_MIGRATE_FOLDERS
  !insertmacro SUITE_RETIRE_COMPONENTS
  !insertmacro SUITE_INSTALL_FILES
  !insertmacro SUITE_PLACE_DEFAULTS

  CreateDirectory "$StartMenuDir"
  !insertmacro SUITE_CREATE_SHORTCUTS

  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "${ARP_ROOT}" "DisplayName"     "${SUITE_NAME}"
  WriteRegStr HKCU "${ARP_ROOT}" "DisplayVersion"  "${SUITEVERSION}"
  WriteRegStr HKCU "${ARP_ROOT}" "Publisher"       "${SUITE_PUB}"
  WriteRegStr HKCU "${ARP_ROOT}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${ARP_ROOT}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${ARP_ROOT}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${ARP_ROOT}" "NoModify" 1
  WriteRegDWORD HKCU "${ARP_ROOT}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${ARP_ROOT}" "EstimatedSize" "$0"
SectionEnd

Function un.onInit
  StrCpy $StartMenuDir "$SMPROGRAMS\${SUITE_NAME}"
  StrCpy $RemoveData 0
  StrCpy $PSExe "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PSExe" +2 0
    StrCpy $PSExe "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
FunctionEnd

; Page after the confirm page: one check box, off by default.
Function un.DataPageShow
  !insertmacro MUI_HEADER_TEXT "Your data" "Choose what happens to your settings, logs, reports and history."
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 54u "Uninstall removes the program files. Your settings, logs, reports and history stay in the suite folders under $INSTDIR. Folders that other tools share are never removed. The last page lists what stays and where."
  Pop $0
  ${NSD_CreateCheckbox} 0 62u 100% 12u "Also delete my data in the suite folders (cannot be undone)"
  Pop $RemoveCheck
  ${NSD_SetState} $RemoveCheck ${BST_UNCHECKED}
  nsDialogs::Show
FunctionEnd

Function un.DataPageLeave
  ${NSD_GetState} $RemoveCheck $RemoveData
FunctionEnd

Section "Uninstall"
  !insertmacro SUITE_DELETE_SHORTCUTS
  RMDir "$StartMenuDir"

  DeleteRegKey HKCU "${ARP_ROOT}"

  ; Only shipped files are deleted; user state written after install stays,
  ; and every directory removal is non-recursive so a folder holding user
  ; files survives.
  !insertmacro SUITE_UNINSTALL_FILES
  Delete "$INSTDIR\suite-manifest.json"

  ; Only the "Also delete my data" check box (never set by /S) removes the
  ; suite folders that hold user state.
  StrCmp $RemoveData ${BST_CHECKED} remove_data keep_data
  remove_data:
  DetailPrint "Deleting your data in the suite folders"
  !insertmacro SUITE_REMOVE_USER_DATA
  keep_data:

  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  !insertmacro SUITE_REPORT_KEPT
SectionEnd
