#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------------------------------------------------------------------------
; By default, use mxswitch.ps1 next to this file. Set SCRIPT to an absolute
; path if your PowerShell or Python switcher is elsewhere.
;
; The host channels come from the mxswitch config file, so the toggle hotkey
; switches to whichever channel is not currently active:
;     Windows  %LOCALAPPDATA%\mxswitch\config
;     others   ~/.config/mxswitch/config      (channel_a=1, channel_b=2)
; ---------------------------------------------------------------------------
SCRIPT := A_ScriptDir "\mxswitch.ps1"

; Start edge switching by setting EDGE to "left" or "right".
EDGE := ""
EDGE_CHANNEL := 1
if (EDGE != "") {
    if (!(EDGE = "left" || EDGE = "right") || EDGE_CHANNEL < 1 || EDGE_CHANNEL > 3
        || !IsInteger(EDGE_CHANNEL))
        throw ValueError("Use left/right and a destination channel from 1 to 3.")
    CheckScriptPath()
    CoordMode "Mouse", "Screen"
    SetTimer WatchEdge, 50
}

CheckScriptPath() {
    global SCRIPT
    if !FileExist(SCRIPT)
        throw Error("mxswitch script not found. Check SCRIPT in mxswitch.ahk.", -1, SCRIPT)
}

; True if SCRIPT ends in .ps1 (PowerShell), otherwise assume Python.
IsPowerShell() {
    global SCRIPT
    return StrLower(SubStr(SCRIPT, -4)) = ".ps1"
}

RunMx(argName, value := "", allDevices := false, wait := false) {
    global SCRIPT
    CheckScriptPath()
    usePowerShell := IsPowerShell()
    if usePowerShell {
        args := value = "" ? "-" argName : "-" argName " " value
        if allDevices
            args .= " -All"
        if wait
            args .= " -QuietUnconfirmed"
        command := Format('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{1}" {2}',
            SCRIPT, args)
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
        if allDevices
            args .= " --all"
        command := Format('pythonw.exe "{1}" {2}', SCRIPT, args)
    }
    if wait {
        exitCode := RunWait(command, , "Hide")
        if (exitCode != 0 && !(usePowerShell && exitCode = 4))
            MsgBox(Format("mxswitch exited with code {1}. Run this command in a terminal:`n`n{2}",
                exitCode, command), "mxswitch")
        return exitCode = 0
    } else {
        Run command, , "Hide"
    }
}

WatchEdge() {
    global EDGE, EDGE_CHANNEL
    static samples := 0
    MouseGetPos &x
    left := SysGet(76)  ; SM_XVIRTUALSCREEN
    right := left + SysGet(78)  ; SM_CXVIRTUALSCREEN
    distance := EDGE = "left" ? x - left : right - x
    dragging := GetKeyState("LButton") || GetKeyState("RButton") || GetKeyState("MButton")

    ; The cursor can stay at the edge while the mouse is on the other host.
    if (dragging || x < left || x >= right)
        samples := 0
    else if (distance >= 12 || (samples && distance > 1))
        samples := 1
    else if (samples && ++samples = 5) {
        samples := 0
        RunMx("Channel", EDGE_CHANNEL, true, true)
    }
}

; Ctrl+Alt+M  ->  hand the mouse over to the other machine
^!m::RunMx("Toggle")

; Ctrl+Alt+Shift+M  ->  hand it over and lock this machine behind you
^!+m:: {
    if RunMx("Toggle", "", false, true)
        DllCall("user32\LockWorkStation")
}

; Explicit channels, in case you ever pair a third host
^!1::RunMx("Channel", "1")
^!2::RunMx("Channel", "2")
^!3::RunMx("Channel", "3")
