@echo off
rem Double-clic : convertit les nouveaux fichiers audio puis les envoie sur R2
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dandy-audio.ps1" %*
pause
