@echo off
rem Double-clic : installe ffmpeg + rclone et configure le dossier de musique et la connexion R2
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
pause
