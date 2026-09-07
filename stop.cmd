@echo off
rem Fully close the Codex desktop app and every codex process it or you started
rem (CLI sessions in terminals, the VS Code extension's app-server, node helpers).
rem Run this before updating the app or when a switch reports "still running".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" -Stop
pause
