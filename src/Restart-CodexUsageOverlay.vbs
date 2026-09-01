Option Explicit

Dim shell, fso, baseDirectory, startScript, wscriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

WScript.Sleep 1200
baseDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
startScript = fso.BuildPath(baseDirectory, "Start-CodexUsageOverlay.vbs")
wscriptPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\wscript.exe")
command = Chr(34) & wscriptPath & Chr(34) & " " & Chr(34) & startScript & Chr(34)
shell.Run command, 0, False
