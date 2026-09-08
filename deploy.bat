@echo off
REM deploy.bat - double-clickable wrapper around deploy.ps1.
REM
REM It contains no logic and it never will. Logic in two languages is logic that
REM diverges. Every argument is passed straight through.
REM
REM For this project deploy.ps1 refuses and explains: cockpit-headscale is a
REM Cockpit plugin and Cockpit is Linux-only, so there is no Windows payload.
REM Read what it prints.
REM
REM -NoProfile so a user's PowerShell profile cannot change what a deploy does.
REM -ExecutionPolicy Bypass for this process only; it changes no machine policy.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
exit /b %ERRORLEVEL%
