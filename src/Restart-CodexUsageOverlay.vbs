Option Explicit

Dim shell, fso, baseDirectory, startScript, wscriptPath, command, attempt, tick, stableSeconds
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
startScript = fso.BuildPath(baseDirectory, "Start-CodexUsageOverlay.vbs")
wscriptPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\wscript.exe")
command = Chr(34) & wscriptPath & Chr(34) & " " & Chr(34) & startScript & Chr(34)

Function IsOverlayRunning()
    Dim service, processes, process, commandLine
    IsOverlayRunning = False
    On Error Resume Next
    Set service = GetObject("winmgmts:\\.\root\cimv2")
    Set processes = service.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='powershell.exe' OR Name='pwsh.exe'")
    For Each process In processes
        commandLine = process.CommandLine
        If Not IsNull(commandLine) Then
            If InStr(1, commandLine, baseDirectory & "\CodexUsageOverlay.ps1", vbTextCompare) > 0 Then
                IsOverlayRunning = True
                Exit For
            End If
        End If
    Next
    On Error GoTo 0
End Function

' Wait for the current instance to release its single-instance mutex.
For tick = 1 To 10
    If Not IsOverlayRunning() Then Exit For
    WScript.Sleep 500
Next

' A new instance can fail shortly after launch. Keep checking until it has
' remained alive for 20 seconds, and retry if it exits during startup.
For attempt = 1 To 3
    shell.Run command, 0, False
    WScript.Sleep 3000
    stableSeconds = 0
    For tick = 1 To 10
        If Not IsOverlayRunning() Then Exit For
        WScript.Sleep 2000
        stableSeconds = stableSeconds + 2
    Next
    If stableSeconds >= 20 Then Exit For
Next
