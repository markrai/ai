@echo off
REM -File forwards %* quoting correctly; -Command "& 'path' %*" breaks quoted prompts.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai.ps1" %*