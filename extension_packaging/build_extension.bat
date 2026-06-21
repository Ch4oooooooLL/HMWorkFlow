@echo off
setlocal

cd /d "%~dp0\.."

python extension_packaging\pack_hmworkflow_extension.py

echo.
echo Build finished.
echo Please check the dist folder.
pause
