@echo off
setlocal
chcp 65001 >nul
title Voice Destroy - Publication des langues

echo ============================================================
echo        VOICE DESTROY - PUBLICATION DES LANGUES
echo ============================================================
echo.
echo Place les dossiers de langues dans "a_publier" avant de continuer.
echo GitHub demandera une connexion dans le navigateur la premiere fois.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\publish-language-packs.ps1"
set "publish_exit=%errorlevel%"

echo.
if not "%publish_exit%"=="0" (
    echo La publication a echoue. Aucun message d'erreur ne doit etre ignore.
) else (
    echo Publication terminee avec succes.
)
echo.
pause
exit /b %publish_exit%
