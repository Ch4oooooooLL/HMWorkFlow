@echo off
chcp 65001 >nul
setlocal
pushd "%~dp0"

echo 正在启动 HMWorkFlow 打包上传流程...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_and_upload.ps1"
set "HM_UPLOAD_EXIT=%ERRORLEVEL%"

echo.
if not "%HM_UPLOAD_EXIT%"=="0" (
    echo 执行失败，退出码：%HM_UPLOAD_EXIT%
) else (
    echo 打包与上传已完成。
)
echo 请查看上方完整输出。
pause

popd
exit /b %HM_UPLOAD_EXIT%
