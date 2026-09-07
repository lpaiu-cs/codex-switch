@echo off
rem List profiles (with account e-mail / plan) and show the active one
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" -List
pause
