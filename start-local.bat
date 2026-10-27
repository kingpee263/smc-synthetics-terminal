@echo off
title SMC Auto-Desk Local MT5 Server (Port 8095)
echo Starting SMC Auto-Desk Server at http://localhost:8095/ ...
start "" "http://localhost:8095/"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
