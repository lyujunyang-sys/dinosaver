' Launch the screensaver with no console window flash.
Dim sh, p, full
Set sh = CreateObject("WScript.Shell")
full = WScript.ScriptFullName
p = Left(full, InStrRev(full, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & p & "dino_saver.ps1""", 0, False
