@echo off
cd /d "%~dp0"
resticprofile schedule --all
pause
