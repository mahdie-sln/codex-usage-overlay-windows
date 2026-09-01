Option Explicit

Dim shell, fso, baseDirectory, pwshPath, powerShellPath, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDirectory, "CodexUsageOverlay.ps1")
pwshPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%ProgramFiles%"), "PowerShell\7\pwsh.exe")
powerShellPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\WindowsPowerShell\v1.0\powershell.exe")

If fso.FileExists(pwshPath) Then
    command = Chr(34) & pwshPath & Chr(34)
Else
    command = Chr(34) & powerShellPath & Chr(34)
End If

command = command & " -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File " & Chr(34) & scriptPath & Chr(34)
shell.Run command, 0, False
