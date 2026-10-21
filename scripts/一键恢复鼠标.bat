@echo off
chcp 65001 >nul
title 复位罗技 G304 接收器

rem 复位接收器需要管理员权限，但守护进程（LogitechG304Guard）本身以 SYSTEM 权限运行。
rem 所以这里只写一个请求文件，由守护代为执行 —— 不需要弹 UAC。
set "REQ=E:\LogitechMouseFix\state\repair.request"
set "DONE=E:\LogitechMouseFix\state\repair.done"

if exist "%DONE%" del "%DONE%" >nul 2>&1
echo 正在复位罗技接收器...
>"%REQ%" echo request

rem 等待守护处理（轮询周期约 3-4 秒）
for /l %%i in (1,1,20) do (
    if exist "%DONE%" goto :done
    timeout /t 1 /nobreak >nul 2>&1
)

rem 守护没响应（例如它没在运行），退回到直接提权执行
if not exist "%DONE%" (
    echo 守护未响应，改用管理员方式直接复位...
    powershell -NoProfile -Command "Start-Process -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','E:\LogitechMouseFix\Recover-Mouse.ps1' -Verb RunAs -Wait"
    goto :end
)

:done
echo 完成。鼠标应该已经恢复，约需 4-5 秒。

:end
echo.
timeout /t 4 /nobreak >nul 2>&1
exit /b 0
