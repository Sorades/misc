@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

rem ============================================================
rem mihomo Windows 下载并启动脚本
rem 配置文件位置：脚本同目录\mihomo\data\config.yaml
rem ============================================================

set "VERSION=v1.19.26"
set "CPU=v3"

set "ROOT=%~dp0mihomo"
set "BIN=%ROOT%\bin"
set "DATA=%ROOT%\data"
set "EXE=%BIN%\mihomo.exe"
set "MARK=%BIN%\.version"

set "PACKAGE=mihomo-windows-amd64-%CPU%-%VERSION%.zip"
set "URL=https://github.com/MetaCubeX/mihomo/releases/download/%VERSION%/%PACKAGE%"
set "ZIP=%TEMP%\%PACKAGE%"
set "TMP=%TEMP%\mihomo_extract_%RANDOM%%RANDOM%"

echo.
echo [mihomo] Version : %VERSION%
echo [mihomo] CPU     : %CPU%
echo [mihomo] Home    : %ROOT%
echo.

if not exist "%BIN%" mkdir "%BIN%" >nul 2>&1
if not exist "%DATA%" mkdir "%DATA%" >nul 2>&1

set "NEED_DOWNLOAD=1"

if exist "%EXE%" if exist "%MARK%" (
    set /p INSTALLED=<"%MARK%"
    if /i "!INSTALLED!"=="%VERSION%-%CPU%" (
        set "NEED_DOWNLOAD=0"
    )
)

if "%NEED_DOWNLOAD%"=="1" (
    echo [mihomo] 正在下载：
    echo %URL%
    echo.

    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$ErrorActionPreference='Stop';" ^
        "$ProgressPreference='SilentlyContinue';" ^
        "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
        "Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%ZIP%'"

    if errorlevel 1 (
        echo.
        echo [错误] 下载失败，请检查网络、版本号或下载地址。
        exit /b 1
    )

    if exist "%TMP%" rmdir /s /q "%TMP%"

    echo [mihomo] 正在解压...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$ErrorActionPreference='Stop';" ^
        "Expand-Archive -LiteralPath '%ZIP%' -DestinationPath '%TMP%' -Force"

    if errorlevel 1 (
        echo.
        echo [错误] 解压失败。
        exit /b 1
    )

    set "FOUND_EXE="
    for /r "%TMP%" %%F in (mihomo*.exe) do (
        if not defined FOUND_EXE set "FOUND_EXE=%%~fF"
    )

    if not defined FOUND_EXE (
        echo.
        echo [错误] 压缩包中未找到 mihomo 可执行文件。
        exit /b 1
    )

    copy /y "!FOUND_EXE!" "%EXE%" >nul
    >"%MARK%" echo %VERSION%-%CPU%

    del /q "%ZIP%" >nul 2>&1
    rmdir /s /q "%TMP%" >nul 2>&1

    echo [mihomo] 安装完成：%EXE%
) else (
    echo [mihomo] 已安装目标版本，跳过下载。
)

echo.

if not exist "%DATA%\config.yaml" (
    echo [错误] 未找到配置文件：
    echo %DATA%\config.yaml
    echo.
    echo 请将 mihomo 配置文件保存到上述位置，然后重新运行此脚本。
    exit /b 2
)

echo [mihomo] 正在启动...
echo [mihomo] 配置目录：%DATA%
echo [mihomo] 按 Ctrl+C 可停止运行。
echo.

"%EXE%" -d "%DATA%"

set "EXITCODE=%ERRORLEVEL%"
echo.
echo [mihomo] 已退出，返回值：%EXITCODE%
exit /b %EXITCODE%
