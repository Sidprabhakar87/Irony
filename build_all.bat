@echo off
REM ============================================================================
REM Synaptyx Referee - Complete Build Script
REM ============================================================================
REM Builds everything in one command:
REM   1. Zig DLL (irony_injector.exe, irony_t7.dll, irony_t8.dll)
REM   2. Python Intelligence Service (synaptyx_intelligence)
REM   3. Packages into dist/ folder ready for deployment
REM ============================================================================

setlocal enabledelayedexpansion

echo.
echo ============================================================
echo   SYNAPTYX REFEREE - BUILD ALL
echo ============================================================
echo.

REM Check prerequisites
echo [1/6] Checking prerequisites...

where zig >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Zig compiler not found in PATH.
    echo Please install Zig 0.15.2 from https://ziglang.org/download/
    exit /b 1
)

where python >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Python not found in PATH.
    echo Please install Python 3.11+ from https://python.org
    exit /b 1
)

for /f "tokens=2 delims= " %%v in ('zig version') do set ZIG_VERSION=%%v
echo   Zig: %ZIG_VERSION%

for /f "tokens=2 delims= " %%v in ('python --version') do set PY_VERSION=%%v
echo   Python: %PY_VERSION%
echo   OK
echo.

REM Build Zig components
echo [2/6] Building Zig components (release mode)...
zig build --release=fast
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Zig build failed!
    exit /b 1
)
echo   irony_injector.exe  - OK
echo   irony_t7.dll        - OK
echo   irony_t8.dll        - OK
echo.

REM Install Python dependencies
echo [3/6] Installing Python dependencies...
cd synaptyx_intelligence
python -m pip install -e ".[dev]" --quiet 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo WARNING: pip install failed, trying without dev deps...
    python -m pip install -e . --quiet
)
cd ..
echo   synaptyx-intelligence - OK
echo.

REM Package into dist folder
echo [4/6] Packaging into dist/ folder...
if not exist "dist" mkdir dist
if not exist "dist\synaptyx_intelligence" mkdir dist\synaptyx_intelligence

copy /Y zig-out\bin\irony_injector.exe dist\ >nul
copy /Y zig-out\bin\irony_t7.dll dist\ >nul
copy /Y zig-out\bin\irony_t8.dll dist\ >nul
xcopy /Y /E /Q synaptyx_intelligence\*.py dist\synaptyx_intelligence\ >nul 2>&1
copy /Y synaptyx_intelligence\pyproject.toml dist\synaptyx_intelligence\ >nul
echo   dist/ folder created - OK
echo.

REM Create launcher script
echo [5/6] Creating launcher scripts...
(
echo @echo off
echo REM Synaptyx Referee - One-Click Launcher
echo REM Starts the intelligence service in system tray, then injects into game
echo echo Starting Synaptyx Intelligence Service...
echo start /B pythonw -m synaptyx_intelligence.tray
echo timeout /t 2 /nobreak ^>nul
echo echo Injecting into Tekken 8...
echo start irony_injector.exe
echo echo.
echo echo Synaptyx Referee is running.
echo echo - Intelligence service: system tray icon
echo echo - Game overlay: press Tab in-game
echo echo.
echo pause
) > dist\synaptyx_launch.bat
echo   synaptyx_launch.bat - OK
echo.

REM Create settings template
echo [6/6] Creating default configuration...
if not exist "dist\.env" (
    (
echo # Synaptyx Intelligence Configuration
echo # Copy this file to .env and modify as needed
echo.
echo # Service settings
echo SYNAPTYX_SERVICE_HOST=127.0.0.1
echo SYNAPTYX_SERVICE_PORT=8400
echo SYNAPTYX_DEBUG=false
echo.
echo # Tournament Platform API
echo SYNAPTYX_PLATFORM_API_URL=
echo SYNAPTYX_PLATFORM_API_KEY=
echo.
echo # Referee
echo SYNAPTYX_REFEREE_ENABLED=true
echo SYNAPTYX_REFEREE_STRICTNESS=normal
echo SYNAPTYX_REFEREE_MATCH_ID=
echo.
echo # Coach
echo SYNAPTYX_COACH_ENABLED=true
echo SYNAPTYX_COACH_ANALYSIS_DEPTH=detailed
echo.
echo # ML ^(future^)
echo SYNAPTYX_ML_ENABLED=false
echo SYNAPTYX_DATA_COLLECTION_ENABLED=false
    ) > dist\.env.example
)
echo   .env.example - OK
echo.

echo ============================================================
echo   BUILD COMPLETE
echo ============================================================
echo.
echo Output in: dist\
echo.
echo To run:
echo   cd dist
echo   synaptyx_launch.bat
echo.
echo Or manually:
echo   1. Start intelligence: python -m synaptyx_intelligence.tray
echo   2. Start injector:     irony_injector.exe
echo   3. Launch Tekken 8 via Steam
echo   4. Press Tab for overlay
echo.

endlocal
