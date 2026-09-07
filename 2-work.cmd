@echo off
rem Switch to the 'work' profile, then launch Codex
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" work
