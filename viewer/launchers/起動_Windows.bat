@echo off
chcp 65001 >nul
cd /d "%~dp0"
title パズルルート PCビューアー
echo パズルルート PCビューアーを起動します。
echo 「Windows セキュリティの重要な警告」が出たら「プライベート ネットワーク」にチェックして「アクセスを許可する」を押してください。
echo.
puzzleroute-viewer-windows.exe
if errorlevel 1 pause
