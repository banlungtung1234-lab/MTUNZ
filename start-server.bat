@echo off
setlocal
cd /d "%~dp0"
set MTUNZ_ADDR=:8787
echo ==================================================
echo  MTUNZ Signaling Server - LAN development mode
echo  Listen: http://0.0.0.0:8787
echo  Health: http://127.0.0.1:8787/healthz
echo ==================================================
echo.
echo On the phone, set the server address to the PC Wi-Fi IPv4 address.
echo Use ipconfig to find that address. Allow Private network access only.
echo Do not expose port 8787 directly to the public Internet.
echo.
MTUNZ-Signaling-Windows.exe
pause
