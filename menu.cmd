@echo off
rem Interactive menu: add accounts / switch between Codex profiles by number
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" -Menu
