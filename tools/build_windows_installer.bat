@echo off
setlocal enabledelayedexpansion
REM ───────────────────────────────────────────────────────────────
REM  Lyra — Windows installer build script
REM
REM  Prerequisites (all standard for the Lyra Windows dev setup):
REM    1. Visual Studio 2022/2026 with C++ desktop workload
REM    2. Qt 6.11 installed via Qt Online Installer
REM    3. Vulkan SDK  (https://vulkan.lunarg.com/sdk/home#windows)
REM    4. Inno Setup 6  (https://jrsoftware.org/isdl.php)
REM    5. CMake 3.28+   (ships with VS, or standalone)
REM    6. Ninja          (ships with VS, or standalone)
REM
REM  Run from a "Developer Command Prompt for VS" or after calling
REM  vcvarsall.bat x64, so cl.exe and the VC toolset are on PATH.
REM
REM  Usage:
REM    tools\build_windows_installer.bat [branch]
REM
REM  Default branch: qt-observatory-theme
REM  Output:         dist\Lyra-Setup-0.25.44.exe
REM ───────────────────────────────────────────────────────────────

set "BRANCH=%~1"
if "%BRANCH%"=="" set "BRANCH=qt-observatory-theme"

REM ── Verify we're in a VS developer environment ─────────────
where cl.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: cl.exe not found.  Run this from a Developer Command Prompt
    echo        or call vcvarsall.bat x64 first.
    exit /b 1
)

REM ── Verify Qt is findable ──────────────────────────────────
where qmake.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: qmake.exe not found.  Add your Qt 6.11 bin directory to PATH, e.g.:
    echo        set PATH=C:\Qt\6.11.0\msvc2022_64\bin;%%PATH%%
    exit /b 1
)

REM ── Verify Inno Setup ──────────────────────────────────────
set "ISCC="
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)
if "%ISCC%"=="" (
    where ISCC.exe >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Inno Setup 6 not found.  Install from https://jrsoftware.org/isdl.php
        exit /b 1
    )
    for /f "delims=" %%i in ('where ISCC.exe') do set "ISCC=%%i"
)

echo.
echo ══════════════════════════════════════════════
echo  Lyra Windows Installer Build
echo ══════════════════════════════════════════════
echo  Branch: %BRANCH%
echo  ISCC:   %ISCC%
echo.

REM ── Checkout the branch ────────────────────────────────────
git fetch origin
git checkout %BRANCH% || (
    echo ERROR: Could not checkout branch %BRANCH%
    exit /b 1
)
git pull origin %BRANCH%

REM ── Configure ──────────────────────────────────────────────
echo.
echo ── CMake configure ───────────────────────────
cmake -B build -G Ninja ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH="%Qt6_DIR%" ^
    || (
    echo ERROR: CMake configure failed.
    exit /b 1
)

REM ── Build ──────────────────────────────────────────────────
echo.
echo ── CMake build ───────────────────────────────
cmake --build build --config Release --parallel || (
    echo ERROR: Build failed.
    exit /b 1
)
echo.
echo  Build complete.  windeployqt ran as a POST_BUILD step,
echo  so build\ should be a self-contained deployment tree.

REM ── Package with Inno Setup ────────────────────────────────
echo.
echo ── Inno Setup ────────────────────────────────
if not exist dist mkdir dist
"%ISCC%" installer\lyra.iss || (
    echo ERROR: Inno Setup failed.
    exit /b 1
)

echo.
echo ══════════════════════════════════════════════
echo  SUCCESS
echo  Installer: dist\Lyra-Setup-0.25.44.exe
echo ══════════════════════════════════════════════
