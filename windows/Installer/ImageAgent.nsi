Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"

Name "ImageAgent"
OutFile "${OUTPUT_EXE}"
InstallDir "$LOCALAPPDATA\Programs\ImageAgent"
InstallDirRegKey HKCU "Software\ImageAgent" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${VERSION_QUAD}"
VIAddVersionKey /LANG=2052 "ProductName" "ImageAgent"
VIAddVersionKey /LANG=2052 "FileDescription" "ImageAgent Windows 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "ImageAgent"
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\ImageAgent.exe"
!define MUI_FINISHPAGE_RUN_TEXT "运行 ImageAgent"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  SetShellVarContext current
  SetRegView 64
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "ImageAgent 需要 Windows 10 或 Windows 11。"
    Abort
  ${EndIf}
!if "${APP_RID}" == "win-arm64"
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_ICONSTOP "这是 ARM64 版本，请为 Intel/AMD 电脑使用 x64 安装包。"
    Abort
  ${EndIf}
!else
  ${IfNot} ${IsNativeAMD64}
    MessageBox MB_ICONSTOP "这是 x64 版本，请为 ARM64 电脑使用 ARM64 安装包。"
    Abort
  ${EndIf}
!endif
FunctionEnd

Section "ImageAgent" MainSection
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}/*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\ImageAgent" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "DisplayName" "ImageAgent"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "Publisher" "ImageAgent"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "DisplayIcon" "$INSTDIR\ImageAgent.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "EstimatedSize" ${ESTIMATED_SIZE_KB}
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent" "NoRepair" 1
  CreateDirectory "$SMPROGRAMS\ImageAgent"
  CreateShortcut "$SMPROGRAMS\ImageAgent\ImageAgent.lnk" "$INSTDIR\ImageAgent.exe"
  CreateShortcut "$SMPROGRAMS\ImageAgent\卸载 ImageAgent.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\ImageAgent.lnk" "$INSTDIR\ImageAgent.exe"
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
FunctionEnd

Section "Uninstall"
  ; Delete only our installed files. Do not recursively remove a user-selected folder.
  !include "${UNINSTALL_INCLUDE}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\ImageAgent\ImageAgent.lnk"
  Delete "$SMPROGRAMS\ImageAgent\卸载 ImageAgent.lnk"
  RMDir "$SMPROGRAMS\ImageAgent"
  Delete "$DESKTOP\ImageAgent.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageAgent"
  DeleteRegKey HKCU "Software\ImageAgent"
  ; LocalAppData\ImageAgent and Windows Credential Manager entries deliberately remain.
SectionEnd
