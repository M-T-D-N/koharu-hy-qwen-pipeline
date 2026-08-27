@echo off
setlocal

set "PWSH_EXE="
if exist "%~dp0config\local-runtime.cmd" call "%~dp0config\local-runtime.cmd"
if defined KOHARU_PWSH_EXECUTABLE if exist "%KOHARU_PWSH_EXECUTABLE%" set "PWSH_EXE=%KOHARU_PWSH_EXECUTABLE%"
if not defined PWSH_EXE if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH_EXE if exist "%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe" set "PWSH_EXE=%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe"
if not defined PWSH_EXE where.exe /q pwsh.exe && set "PWSH_EXE=pwsh.exe"

if not defined PWSH_EXE (
  echo PowerShell 7 was not found. Install it from https://aka.ms/powershell-release
  pause
  exit /b 9009
)

"%PWSH_EXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\launcher.ps1" %*
if errorlevel 1 pause
endlocal
