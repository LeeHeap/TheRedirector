@echo off
:: TheRedirector launcher
:: Requests UAC elevation then starts the app in STA mode (required for WPF)

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process PowerShell -Verb RunAs -ArgumentList '-STA -NoProfile -ExecutionPolicy Bypass -File ""%~dp0TheRedirector.ps1""'"
