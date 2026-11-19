@echo off
rem =====================================================================
rem make.bat - build the compiler itself: NcuFuck.asm -> NcuFuck.exe
rem (no debug info, so no .pdb / .ilk; the .obj is deleted afterwards)
rem
rem Usage: make
rem =====================================================================
setlocal
cd /d "%~dp0"

where ml >nul 2>&1
if errorlevel 1 call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1

ml /nologo /c /coff /I C:\Irvine NcuFuck.asm
if errorlevel 1 goto fail
link /nologo /SUBSYSTEM:CONSOLE /ENTRY:start /LIBPATH:C:\Irvine NcuFuck.obj Irvine32.lib kernel32.lib user32.lib
if errorlevel 1 goto fail

del NcuFuck.obj 2>nul
echo OK: NcuFuck.exe
exit /b 0

:fail
del NcuFuck.obj 2>nul
echo Build FAILED
exit /b 1
