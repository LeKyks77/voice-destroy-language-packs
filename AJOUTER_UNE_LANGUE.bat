@echo off
setlocal
chcp 65001 >nul
title Voice Destroy - Assistant de langue

echo ============================================================
echo         VOICE DESTROY - AJOUTER UNE LANGUE
echo ============================================================
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\new-language-wizard.ps1"
set "wizard_exit=%errorlevel%"

echo.
if not "%wizard_exit%"=="0" (
    echo La preparation a echoue. Lis le message affiche au-dessus.
) else (
    echo Preparation terminee.
)
echo.
pause
exit /b %wizard_exit%
