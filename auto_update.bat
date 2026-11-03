@echo off
REM ============================================================
REM  TVBox config auto-updater (Gitee edition)
REM  Fetch upstream -> merge/dedup -> push back to Gitee
REM  Called by Windows Task Scheduler (SYSTEM account) every 12 hours.
REM
REM  IMPORTANT:
REM   1) This file must stay pure ASCII. cmd.exe decodes .bat as GBK;
REM      a UTF-8 Chinese path in it gets mangled and breaks the script.
REM   2) Work dir must be a real ASCII path, not a subst drive.
REM      Task Scheduler runs as SYSTEM and cannot see session-level
REM      subst mappings.
REM ============================================================
setlocal

set "WORKDIR=E:\TVBOX"
set "PY=C:\Users\Administrator\.workbuddy\binaries\python\versions\3.13.12\python.exe"
set "BASH=C:\Users\Administrator\.workbuddy\binaries\PortableGit\versions\1.3.0\bin\bash.exe"

cd /d "%WORKDIR%" || exit /d 1

echo [%date% %time%] ===== update start =====

REM 1) regenerate artifacts
"%PY%" scripts\build.py
if errorlevel 1 (
    echo [%date% %time%] !! build failed, keeping previous artifacts
    exit /d 1
)

REM 2) push to Gitee
"%BASH%" gitee.sh push . tvbox master
if errorlevel 1 (
    echo [%date% %time%] !! push failed
    exit /d 1
)

echo [%date% %time%] ===== update done =====
exit /d 0
