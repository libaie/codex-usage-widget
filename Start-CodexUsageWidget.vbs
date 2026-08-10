Option Explicit

Dim fso, shell, directory, scriptPath, powershellPath, command
Dim result

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
directory = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(directory, "CodexUsageWidget.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fso.FileExists(scriptPath) Or Not fso.FileExists(powershellPath) Then WScript.Quit 2

command = """" & powershellPath & """ -NoProfile -ExecutionPolicy Bypass -STA -File """ & scriptPath & """"
' ponytail: WSH hides all console UI; powershell.exe may retain a headless conhost process.
result = shell.Run(command, 0, False)
WScript.Quit result
