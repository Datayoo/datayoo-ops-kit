@echo off
rem Thin CMD wrapper around install-lib.ps1.
rem   install-lib.bat
rem   install-lib.bat C:\path\to\repository
rem   install-lib.bat C:\path\to\repository --force
setlocal
cd /d "%~dp0"

set "SCRIPT=%~dp0install-lib.ps1"
set "REPO="
set "FORCE="

:parse
if "%~1"=="" goto run
if /I "%~1"=="--force" (set "FORCE=1" & shift & goto parse)
if /I "%~1"=="-f"      (set "FORCE=1" & shift & goto parse)
if /I "%~1"=="-force"  (set "FORCE=1" & shift & goto parse)
set "REPO=%~1"
shift
goto parse

:run
if defined REPO (
  if defined FORCE (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Repo "%REPO%" -Force
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Repo "%REPO%"
  )
) else (
  if defined FORCE (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Force
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
  )
)

exit /b %ERRORLEVEL%
