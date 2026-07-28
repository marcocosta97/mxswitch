#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------------------------------------------------------------------------
; Edit these two lines.
;   SCRIPT : full path to windows\mxswitch.ps1 (preferred) or python\mxswitch.py
;   TARGET : the Easy-Switch channel the other machine is paired on (1-3)
; ---------------------------------------------------------------------------
SCRIPT := "C:\Path\To\mxswitch\windows\mxswitch.ps1"
TARGET := 2

Switch(channel) {
    global SCRIPT
    ; PowerShell script: pass -Channel. Python script: pass the bare number.
    if (StrLower(SubStr(SCRIPT, -4)) = ".ps1") {
        Run(Format(
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{1}" -Channel {2}',
            SCRIPT, channel), , "Hide")
    } else {
        ; Use pythonw.exe so no console window flashes.
        Run(Format('pythonw.exe "{1}" {2}', SCRIPT, channel), , "Hide")
    }
}

; Ctrl+Alt+M  ->  hand the mouse over to the other machine
^!m::Switch(TARGET)

; Ctrl+Alt+Shift+M  ->  hand it over and lock this machine behind you
^!+m:: {
    Switch(TARGET)
    Sleep 500                                ; let the frame go out first
    DllCall("user32\LockWorkStation")
}

; Explicit channels, in case you ever pair a third host
^!1::Switch(1)
^!2::Switch(2)
^!3::Switch(3)
