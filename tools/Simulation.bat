@echo off
rem Double-clic : montre ce qui serait fait, sans rien convertir ni envoyer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dandy-audio.ps1" -Simulation
pause
