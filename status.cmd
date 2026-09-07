@echo off
rem Show which account is logged in right now, its plan, and how fresh the token is
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" -Status
pause
