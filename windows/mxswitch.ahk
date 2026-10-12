#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------------------------------------------------------------------------
; Edit this line.
;   SCRIPT : full path to windows\mxswitch.ps1 (preferred) or python\mxswitch.py
;
; The host channels come from the mxswitch config file, so the toggle hotkey
; switches to whichever channel is not currently active:
;     Windows  %LOCALAPPDATA%\mxswitch\config
;     others   ~/.config/mxswitch/config      (channel_a=1, channel_b=2)
; ---------------------------------------------------------------------------
SCRIPT := "C:\Path\To\mxswitch\windows\mxswitch.ps1"

; True if SCRIPT ends in .ps1 (PowerShell), otherwise assume Python.
IsPowerShell() {
    global SCRIPT
    return StrLower(SubStr(SCRIPT, -4)) = ".ps1"
}

; Run mxswitch with the given arguments. PowerShell gets -Name switches,
; Python gets --name flags.
RunMx(argName, value := "") {
    global SCRIPT
    if (IsPowerShell()) {
        args := value = "" ? "-" argName : "-" argName " " value
        Run(Format('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{1}" {2}',
            SCRIPT, args), , "Hide")
    } else {
        ; Python takes the channel as a positional argument; the rest are flags
        ; (--toggle, ...). Passing --channel is not accepted by mxswitch.py.
        if (argName = "Channel") {
            args := value
        } else if (value = "") {
            args := "--" StrLower(argName)
        } else {
            args := "--" StrLower(argName) " " value
        }
        ; Use pythonw.exe so no console window flashes.
        Run(Format('pythonw.exe "{1}" {2}', SCRIPT, args), , "Hide")
    }
}

; Ctrl+Alt+M  ->  hand the mouse over to the other machine
^!m::RunMx("Toggle")

; Ctrl+Alt+Shift+M  ->  hand it over and lock this machine behind you
^!+m:: {
    RunMx("Toggle")
    Sleep 500                                ; let the frame go out first
    DllCall("user32\LockWorkStation")
}

; Explicit channels, in case you ever pair a third host
^!1::RunMx("Channel", "1")
^!2::RunMx("Channel", "2")
^!3::RunMx("Channel", "3")
