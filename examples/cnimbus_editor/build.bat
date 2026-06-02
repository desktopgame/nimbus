@echo off
REM Build cnimbus_editor "the naive way": compile main.c against the prebuilt
REM nimbus C ABI with zig cc, then drop the exe + nimbus.dll right here so it
REM runs in place. Dynamic link, so the DLL must sit next to the exe.
REM
REM Prerequisite: run `zig build` once at the repo root (produces zig-out/).
REM Usage (from anywhere):  examples\cnimbus_editor\build.bat
setlocal
set "HERE=%~dp0"
set "OUT=%HERE%..\..\zig-out"

if not exist "%OUT%\bin\nimbus.dll" ( echo [cnimbus_editor] %OUT%\bin\nimbus.dll not found - run "zig build" at the repo root first.& exit /b 1 )

echo [cnimbus_editor] compiling with zig cc...
zig cc "%HERE%main.c" -I "%OUT%\include" -L "%OUT%\lib" -lnimbus -o "%HERE%cnimbus_editor.exe" || exit /b 1

echo [cnimbus_editor] copying nimbus.dll...
copy /y "%OUT%\bin\nimbus.dll" "%HERE%nimbus.dll" >nul || exit /b 1

echo [cnimbus_editor] done: cnimbus_editor.exe + nimbus.dll are in %HERE%
echo [cnimbus_editor] run it with: "%HERE%cnimbus_editor.exe"
endlocal
