@echo off
"%SystemRoot%\System32\wscript.exe" //B //NoLogo "%~dp0Start-CodexUsageWidget.vbs"
exit /b %errorlevel%
