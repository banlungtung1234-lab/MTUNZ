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
echo In MTUNZ Windows Settings, scan WI-FI / ETHERNET / USB adapters.
echo Choose the IPv4 address the Android device can reach:
echo - Wi-Fi or Ethernet on the same local network
echo - RNDIS / USB when Android USB tethering is enabled
echo Use ipconfig if you need to inspect adapter IPv4 addresses.
echo Allow Private network access only when Windows Firewall asks.
echo Do not expose port 8787 directly to the public Internet.
echo.
MTUNZ-Signaling-Windows.exe
pause
