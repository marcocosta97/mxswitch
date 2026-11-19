<#
.SYNOPSIS
    Switch a Logitech Easy-Switch device to another channel via HID++ ChangeHost.

.DESCRIPTION
    No modules, no Python, no admin rights. P/Invokes hid.dll and setupapi.dll,
    which ship with Windows.

.EXAMPLE
    .\mxswitch.ps1 -List
    .\mxswitch.ps1 -Info
    .\mxswitch.ps1 -Status
    .\mxswitch.ps1 -Channel 2
    .\mxswitch.ps1 -All -Channel 2
    .\mxswitch.ps1 -All -Channel 1 -Edge Right
    .\mxswitch.ps1 -Toggle

.NOTES
    If the execution policy blocks this:
        powershell -ExecutionPolicy Bypass -File .\mxswitch.ps1 -Channel 2
    Add-Type will not work under Constrained Language Mode; check with
        $ExecutionContext.SessionState.LanguageMode

    Config (optional), key=value lines in %LOCALAPPDATA%\mxswitch\config:
        channel_a=1
        channel_b=2
        device=primary|all

    Exit codes: 0 ok, 1 operation failed, 2 bad usage, 3 partial failure.
    With -QuietUnconfirmed, exit 4 means an inconclusive switch without a confirmed failure.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [int]$Channel,

    [switch]$Info,
    [switch]$Status,
    [switch]$List,
    [switch]$All,
    [switch]$Toggle,
    [switch]$DryRun,
    [switch]$Json,
    [string]$Config,

    # Only act on devices whose product name contains one of these substrings.
    [ValidateNotNullOrEmpty()]
    [string[]]$Name,

    # Skip the cached device paths and force a full rescan.
    [switch]$NoCache,

    # Give unattended callers an exit code for inconclusive switches.
    [switch]$QuietUnconfirmed,

    [ValidateSet('Left', 'Right')]
    [string]$Edge
)

$ErrorActionPreference = 'Stop'

# Write-Error would terminate under $ErrorActionPreference = 'Stop' and pre-empt
# the exit codes below, so user-facing failures go straight to stderr instead.
function Write-MxError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

$VID = 0x046D
$SW_ID = 0x0A
$DEVICE_INDICES = @(0xFF, 1, 2, 3, 4, 5, 6)

# Built explicitly so the keys are unambiguously integers.
$FRAME_LEN = @{}
$FRAME_LEN[[int]0x10] = 7
$FRAME_LEN[[int]0x11] = 20

$CacheFile = Join-Path $env:LOCALAPPDATA 'mxswitch\device.json'
$ConfigFile = Join-Path $env:LOCALAPPDATA 'mxswitch\config'

# ---------------------------------------------------------------------------
# Pure protocol helpers (hardware-free; exercised by tests)
# ---------------------------------------------------------------------------

function New-HidppFrame {
    param([int]$ReportId, [int]$DevIdx, [int]$FeatureIdx, [int]$Function,
          [byte[]]$Params = @())

    $len = $FRAME_LEN[[int]$ReportId]
    if (-not $len) { throw "unknown report id $ReportId" }
    if ($Params.Count -gt ($len - 4)) { throw "frame too long for report $ReportId" }

    $frame = New-Object byte[] $len
    $frame[0] = $ReportId
    $frame[1] = $DevIdx
    $frame[2] = $FeatureIdx
    $frame[3] = ($Function -shl 4) -bor $SW_ID
    for ($i = 0; $i -lt $Params.Count; $i++) { $frame[4 + $i] = $Params[$i] }
    return ,$frame
}

function Get-ReplyVerdict {
    param([byte[]]$Reply, [int]$DevIdx, [int]$FeatureIdx, [int]$Function = 0, [int]$SwId = $SW_ID)

    if ($null -eq $Reply -or $Reply.Length -lt 5) { return 'too_short' }
    if ($Reply[0] -notin @(0x10, 0x11)) { return 'ignore' }
    if ($Reply.Length -lt $FRAME_LEN[[int]$Reply[0]]) { return 'too_short' }
    if ($Reply[1] -ne $DevIdx -and -not ($DevIdx -eq 255 -and $Reply[1] -eq 0)) { return 'ignore' }
    $header = ($Function -shl 4) -bor $SwId
    if ($Reply[2] -eq 0xFF -or $Reply[2] -eq 0x8F) {
        if ($Reply.Length -lt 6) { return 'too_short' }
        if ($Reply[3] -eq $FeatureIdx -and $Reply[4] -eq $header) { return 'error' }
        return 'ignore'
    }
    if ($Reply[2] -ne $FeatureIdx) { return 'ignore' }                 # notification
    if ($Reply[3] -ne $header) { return 'ignore' }
    return 'match'
}

function Get-MxConfig {
    param([string]$Path = $ConfigFile)

    $cfg = [ordered]@{ channel_a = 1; channel_b = 2; device = 'primary'; name = '' }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            $clean = ($line -split '#', 2)[0].Trim()
            if (-not $clean) { continue }
            $parts = $clean -split '=', 2
            if ($parts.Count -lt 2) { continue }
            $key = $parts[0].Trim().ToLowerInvariant()
            $value = $parts[1].Trim()
            switch ($key) {
                'channel_a' { $cfg.channel_a = if ($value -match '^[123]$') { [int]$value } else { 0 } }
                'channel_b' { $cfg.channel_b = if ($value -match '^[123]$') { [int]$value } else { 0 } }
                'device'    { $cfg.device = $value.ToLowerInvariant() }
                'name'      { $cfg.name = $value }
            }
        }
    }
    return [pscustomobject]$cfg
}

function Test-MxConfig {
    param($Config)
    $problems = @()
    if ($Config.channel_a -notin @(1,2,3) -or $Config.channel_b -notin @(1,2,3)) {
        $problems += 'channel_a and channel_b must be 1, 2 or 3'
    }
    if ($Config.channel_a -eq $Config.channel_b) {
        $problems += 'channel_a and channel_b must differ'
    }
    if ($Config.device -notin @('primary', 'all')) {
        $problems += 'device must be primary or all'
    }
    return $problems
}

function Format-MxHex {
    param([byte[]]$Bytes)
    ($Bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# Device enumeration and the C# helper are only needed when the script actually
# runs; keeping them behind this guard lets tests dot-source the pure helpers.
if (-not $env:MXSWITCH_TEST -and -not ('Hid' -as [type])) {

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.IO;
using System.Threading.Tasks;

public static class MxEdge {
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x, y; }

    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int key);

    public static bool Advance(ref int samples, int distance, bool blocked) {
        if (blocked || distance < 0) samples = 0;
        else if (distance >= 12) samples = 1;
        else if (samples != 0 && distance > 1) samples = 1;
        else if (samples != 0 && ++samples == 5) {
            samples = 0;
            return true;
        }
        return false;
    }

    public static bool Poll(bool rightEdge, ref int samples) {
        const int SM_XVIRTUALSCREEN = 76, SM_CXVIRTUALSCREEN = 78;
        const int VK_LBUTTON = 1, VK_RBUTTON = 2, VK_MBUTTON = 4;
        POINT point;
        if (!GetCursorPos(out point)) return Advance(ref samples, -1, false);
        int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int right = left + GetSystemMetrics(SM_CXVIRTUALSCREEN) - 1;
        int distance = point.x < left || point.x > right ? -1 :
                       (rightEdge ? right - point.x : point.x - left);
        bool dragging = GetAsyncKeyState(VK_LBUTTON) < 0 ||
                        GetAsyncKeyState(VK_RBUTTON) < 0 ||
                        GetAsyncKeyState(VK_MBUTTON) < 0;
        return Advance(ref samples, distance, dragging);
    }
}

public class Hid {
    const int  DIGCF_PRESENT = 0x02, DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_RW = 0x03, OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    const int  HIDP_STATUS_SUCCESS = 0x00110000;

    [StructLayout(LayoutKind.Sequential)]
    struct GUID { public uint a; public ushort b, c; [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public byte[] d; }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public GUID guid; public int flags; public IntPtr reserved; }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct SP_DEVICE_INTERFACE_DETAIL_DATA_W {
        public int cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=512)] public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES { public int Size; public ushort Vid, Pid, Ver; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputLen, OutputLen, FeatureLen;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
        public ushort LinkNodes, InBtn, InVal, InIdx, OutBtn, OutVal, OutIdx, FtBtn, FtVal, FtIdx;
    }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(ref GUID g);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] static extern int  HidP_GetCaps(IntPtr pp, ref HIDP_CAPS c);
    [DllImport("hid.dll", CharSet=CharSet.Unicode)] static extern bool HidD_GetProductString(SafeFileHandle h, char[] buf, int len);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevsW(ref GUID g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref GUID g, int i, ref SP_DEVICE_INTERFACE_DATA a);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref SP_DEVICE_INTERFACE_DATA a, ref SP_DEVICE_INTERFACE_DETAIL_DATA_W d, int size, IntPtr req, IntPtr info);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    // CancelIoEx, not CancelIo: the async read may have been issued on a
    // thread-pool thread, and CancelIo only cancels the calling thread's I/O.
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CancelIoEx(SafeFileHandle h, IntPtr overlapped);

    public class Iface {
        public string Path, Product;
        public ushort UsagePage, Usage, Pid, InLen, OutLen;
    }

    public static List<Iface> Enumerate(ushort vid) {
        var result = new List<Iface>();
        var guid = new GUID();
        HidD_GetHidGuid(ref guid);
        IntPtr set = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero,
                                          DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return result;   // INVALID_HANDLE_VALUE
        try {
            var did = new SP_DEVICE_INTERFACE_DATA();
            did.cbSize = Marshal.SizeOf(did);
            for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref did); i++) {
                var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA_W();
                // Documented fixed value, NOT SizeOf(): 8 on x64, 6 on x86.
                detail.cbSize = IntPtr.Size == 8 ? 8 : 6;
                if (!SetupDiGetDeviceInterfaceDetailW(set, ref did, ref detail,
                        Marshal.SizeOf(detail), IntPtr.Zero, IntPtr.Zero)) continue;

                using (var h = CreateFileW(detail.DevicePath, 0, FILE_SHARE_RW,
                                           IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                    if (h.IsInvalid) continue;
                    var attrs = new HIDD_ATTRIBUTES(); attrs.Size = Marshal.SizeOf(attrs);
                    if (!HidD_GetAttributes(h, ref attrs) || attrs.Vid != vid) continue;

                    IntPtr pp;
                    if (!HidD_GetPreparsedData(h, out pp)) continue;
                    var caps = new HIDP_CAPS();
                    int ok = HidP_GetCaps(pp, ref caps);
                    HidD_FreePreparsedData(pp);
                    if (ok != HIDP_STATUS_SUCCESS) continue;
                    if (caps.UsagePage < 0xFF00) continue;   // vendor collections only
                    if (caps.OutputLen == 0) continue;       // cannot send anything here

                    var name = new char[128];
                    HidD_GetProductString(h, name, 256);
                    result.Add(new Iface {
                        Path = detail.DevicePath, Product = new string(name).TrimEnd('\0'),
                        UsagePage = caps.UsagePage, Usage = caps.Usage, Pid = attrs.Pid,
                        InLen = caps.InputLen, OutLen = caps.OutputLen });
                }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return result;
    }

    FileStream stream;
    SafeFileHandle handle;
    int inLen, outLen;
    public int OutLen { get { return outLen; } }

    public Hid(Iface iface) {
        var h = CreateFileW(iface.Path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("cannot open " + iface.Path);
        inLen = iface.InLen; outLen = iface.OutLen;
        // bufferSize 1 disables FileStream's internal buffering. Device I/O must
        // reach the driver as whole reports, never coalesced or split.
        try {
            stream = new FileStream(h, FileAccess.ReadWrite, 1, true);
        } catch {
            h.Dispose();
            throw;
        }
        handle = h;
    }

    /*
     * Returns false rather than throwing. Discovery necessarily probes
     * collections that will reject the frame - a collection only accepts report
     * IDs declared in its own descriptor, so sending a 0x10 frame to a
     * long-report collection fails with ERROR_INVALID_PARAMETER. That is a
     * normal, expected outcome of probing, not an error worth aborting on.
     */
    public bool Write(byte[] frame) {
        if (outLen <= 0 || !stream.CanWrite) return false;
        var buf = new byte[outLen];
        Array.Copy(frame, buf, Math.Min(frame.Length, outLen));
        try {
            stream.Write(buf, 0, outLen);
            stream.Flush();
            return true;
        } catch (IOException)          { return false; }
          catch (UnauthorizedAccessException) { return false; }
    }

    static readonly byte[] ReadTimeout = new byte[0];

    // An empty report means timeout. Null means the transport failed.
    public byte[] Read(int timeoutMs) {
        if (inLen <= 0 || !stream.CanRead) return null;
        var buf = new byte[inLen];
        try {
            var task = stream.ReadAsync(buf, 0, inLen);
            if (Task.WaitAny(new Task[] { task }, timeoutMs) != 0) {
                bool cancelled = CancelIoEx(handle, IntPtr.Zero);
                // Drain the cancelled read before using this handle again.
                try { task.Wait(1000); } catch (AggregateException) { }
                if (!task.IsCompleted) { Close(); return null; }
                if (task.Status != TaskStatus.RanToCompletion) return cancelled ? ReadTimeout : null;
            }
            if (task.Status != TaskStatus.RanToCompletion || task.Result <= 0) return null;
            var outb = new byte[task.Result];
            Array.Copy(buf, outb, task.Result);
            return outb;
        } catch (Exception) { return null; }
    }

    public void Close() { try { stream.Dispose(); } catch {} }
}
'@
} # Native API definitions are not needed by hardware-free tests.

function Invoke-HidppCall {
    param($Dev, [int]$ReportId, [int]$DevIdx, [int]$FeatureIdx, [int]$Function,
          [byte[]]$Params = @(), [int]$TimeoutMs = 400, [ref]$Outcome)

    if ($Outcome) { $Outcome.Value = 'timeout' }
    $frame = New-HidppFrame $ReportId $DevIdx $FeatureIdx $Function $Params
    $swId = if ($Dev.PSObject.Properties.Name -contains 'NextSwId') { $Dev.NextSwId } else { $SW_ID }
    $next = 8 + (($swId - 8 + 1) % 8)
    $Dev | Add-Member -NotePropertyName NextSwId -NotePropertyValue $next -Force
    $frame[3] = ($Function -shl 4) -bor $swId
    if (-not $Dev.Write($frame)) {
        if ($Outcome) { $Outcome.Value = 'write-failed' }
        return $null
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (($remaining = $TimeoutMs - [int]$clock.ElapsedMilliseconds) -gt 0) {
        $r = $Dev.Read($remaining)
        if ($null -eq $r) {
            if ($Outcome) { $Outcome.Value = 'read-failed' }
            return $null
        }
        if ($r.Length -eq 0) { break }
        $verdict = Get-ReplyVerdict -Reply $r -DevIdx $DevIdx -FeatureIdx $FeatureIdx -Function $Function -SwId $swId
        if ($verdict -eq 'match') {
            if ($Outcome) { $Outcome.Value = 'reply' }
            return $r
        }
        if ($verdict -eq 'error') {
            if ($Outcome) {
                # Unifying's HID++ 1.0 resource error means the paired slot is disconnected.
                $Outcome.Value = if ($DevIdx -ne 255 -and $r[2] -eq 0x8f -and $r[5] -eq 9) {
                    'disconnected'
                } else { 'error' }
            }
            return $null
        }
    }
    return $null
}

function Resolve-MxFeature {
    param($Dev, [int]$ReportId, [int]$DevIdx, [int]$FeatureId)
    $probe = [byte[]]@((($FeatureId -shr 8) -band 0xFF), ($FeatureId -band 0xFF), 0)
    $r = Invoke-HidppCall $Dev $ReportId $DevIdx 0 0 $probe 300
    if ($r) { return [int]$r[4] }
    return 0
}

function Get-DeviceRank {
    param([int]$UsagePage, [int]$Usage, [string]$Product)
    $n = "$Product".ToLowerInvariant()
    $mouse = ($UsagePage -eq 0x0001 -and $Usage -eq 0x0002) -or
             ($n -match 'master|anywhere|mouse|ergo')
    $kbd = ($UsagePage -eq 0x0001 -and $Usage -eq 0x0006) -or
           ($n -match 'keys|keyboard')
    $tier = if ($kbd -and -not $mouse) { 2 } elseif ($mouse) { 0 } else { 1 }
    $nonVendor = if ($UsagePage -ge 0xFF00) { 0 } else { 1 }
    return (10 * $tier + $nonVendor)
}

# No filter set, or the product name contains any of the substrings.
function Test-MxName {
    param([string]$Product, [string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $true }
    $p = "$Product".ToLowerInvariant()
    foreach ($n in $Names) {
        if ($n -and $p.Contains("$n".ToLowerInvariant())) { return $true }
    }
    return $false
}

# Over Bluetooth some devices (POP Icon Keys) report an empty HID product
# string on Windows; fill in the known name so ranking and -Name still work.
function Resolve-MxProduct {
    param([string]$Product, [int]$ProductId)
    if ($Product) { return $Product }
    if ($ProductId -eq 0xB38F) { return 'POP Icon Keys' }
    return ''
}

# Only live Logitech interfaces supply paths and report sizes to the HID writer.
function Get-CachedDevice {
    param($Interfaces)

    if (-not (Test-Path -LiteralPath $CacheFile -PathType Leaf)) { return }
    try {
        $entry = @(Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json)[0]
        $rid = [int]$entry.ReportId
        $slot = [int]$entry.DevIdx
        $feature = [int]$entry.FeatureIdx
    } catch { return }

    $iface = $Interfaces | Where-Object Path -EQ $entry.Path | Select-Object -First 1
    if (-not $iface -or $slot -notin $DEVICE_INDICES -or $feature -lt 1 -or $feature -gt 255 -or
        -not $FRAME_LEN[$rid] -or $FRAME_LEN[$rid] -gt $iface.OutLen) { return }

    try { $dev = Open-MxDevice $iface } catch { return }
    $keep = $false
    try {
        $probe = [byte[]]@(0x18, 0x14, 0)
        $r = Invoke-HidppCall $dev $rid $slot 0 0 $probe 250
        if (-not $r) {
            $alt = if ($rid -eq 0x11) { 0x10 } else { 0x11 }
            if ($FRAME_LEN[$alt] -le $iface.OutLen) {
                $r = Invoke-HidppCall $dev $alt $slot 0 0 $probe 250
                if ($r) { $rid = $alt }
            }
        }
        if (-not $r -or $r[4] -ne $feature) { return }
        $metadata = Get-MxMetadata $dev $iface $rid $slot
        if ((Get-DeviceRank $iface.UsagePage $iface.Usage $metadata.Product) -ge 10) { return }

        $iface.Product = $metadata.Product
        $keep = $true
        [pscustomobject]@{ Dev=$dev; ReportId=$rid; DevIdx=$slot; FeatureIdx=$feature; Iface=$iface }
    } finally {
        if (-not $keep) { $dev.Close() }
    }
}

function Save-CachedDevice {
    param($Context)

    try {
        $dir = Split-Path $CacheFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $entry = [pscustomobject]@{
            Path=$Context.Iface.Path; DevIdx=$Context.DevIdx
            ReportId=$Context.ReportId; FeatureIdx=$Context.FeatureIdx
        }
        ConvertTo-Json -InputObject $entry | Set-Content -LiteralPath $CacheFile
    } catch { Write-Verbose 'could not write cache' }
}

function Get-MxInterfaces { [Hid]::Enumerate($VID) }
function Open-MxDevice { param($Iface) New-Object Hid $Iface }

function Close-MxDevices {
    param($Contexts)
    $closed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in $Contexts) {
        $shared = $false
        foreach ($dev in $closed) {
            if ([object]::ReferenceEquals($dev, $c.Dev)) { $shared = $true; break }
        }
        if (-not $shared) { $c.Dev.Close(); $closed.Add($c.Dev) }
    }
}

function Get-MxMetadata {
    param($Dev, $Iface, [int]$ReportId, [int]$DevIdx)
    $product = Resolve-MxProduct $Iface.Product $Iface.Pid
    $hasName = $true
    $identity = ($Iface.Path.ToLowerInvariant() -replace '&col[0-9a-f]{2}', '') + ":$DevIdx"
    if ($DevIdx -ne 255) {
        $product = "receiver (slot $DevIdx)"
        $hasName = $false
        $idx = Resolve-MxFeature $Dev $ReportId $DevIdx 0x0005
        if ($idx) {
            $r = Invoke-HidppCall $Dev $ReportId $DevIdx $idx 0
            if ($r -and $r[4]) {
                $length = [int]$r[4]
                $bytes = New-Object 'System.Collections.Generic.List[byte]'
                while ($bytes.Count -lt $length) {
                    $fragment = Invoke-HidppCall $Dev $ReportId $DevIdx $idx 1 ([byte[]]@($bytes.Count))
                    if (-not $fragment -or $fragment.Length -le 4) { break }
                    $n = [Math]::Min($fragment.Length - 4, $length - $bytes.Count)
                    for ($i = 0; $i -lt $n; $i++) { $bytes.Add($fragment[4+$i]) }
                }
                if ($bytes.Count -eq $length) {
                    $product = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
                    $hasName = [bool]$product
                }
            }
        }
    }
    $idx = Resolve-MxFeature $Dev $ReportId $DevIdx 0x0003
    if ($idx) {
        $r = Invoke-HidppCall $Dev $ReportId $DevIdx $idx 0
        if ($r -and $r.Length -ge 9 -and ($r[5] -or $r[6] -or $r[7] -or $r[8])) {
            $identity = 'unit:' + (Format-MxHex ([byte[]]$r[5..8]))
        }
    }
    [pscustomobject]@{ Product = $product; HasName = $hasName; Identity = $identity }
}

# Every slot is discovered before filtering and ranking the peripherals.
function Find-MxDevices {
    param([switch]$All, [string[]]$Names)
    $ifaces = @(Get-MxInterfaces)
    $useCache = -not $NoCache -and -not $All -and -not $Names
    if ($useCache) {
        $cached = Get-CachedDevice $ifaces
        if ($cached) { return $cached }
    }
    $contexts = @(); $opened = @(); $seen = @{}
    try {
        $ifaces = @($ifaces | Sort-Object { Get-DeviceRank $_.UsagePage $_.Usage $_.Product })
        foreach ($iface in $ifaces) {
            $preferred = $false
            try { $dev = Open-MxDevice $iface } catch { continue }
            $opened += [pscustomobject]@{ Dev = $dev }
            $reportIds = @(0x11, 0x10) | Where-Object { $FRAME_LEN[[int]$_] -le $iface.OutLen } |
                Sort-Object @{ Expression = { if ($FRAME_LEN[[int]$_] -eq $iface.OutLen) { 0 } else { 1 } } }
            foreach ($didx in $DEVICE_INDICES) {
                $matched = $false
                foreach ($rid in $reportIds) {
                    Write-Verbose ("probing {0} index=0x{1:x2} report=0x{2:x2}" -f $iface.Product, $didx, $rid)
                    $idx = Resolve-MxFeature $dev $rid $didx 0x1814
                    if ($idx) { $matched = $true; break }
                }
                if (-not $matched) { continue }
                $metadata = Get-MxMetadata $dev $iface $rid $didx
                if (-not $seen.ContainsKey($metadata.Identity) -and
                    (-not $Names -or ($metadata.HasName -and (Test-MxName $metadata.Product $Names)))) {
                    $seen[$metadata.Identity] = $true
                    # Each peripheral needs its own product name, even on a shared handle.
                    $deviceIface = [pscustomobject]@{ Path = $iface.Path; Product = $metadata.Product
                        UsagePage = $(if ($didx -eq 255) { $iface.UsagePage } else { 0 });
                        Usage = $(if ($didx -eq 255) { $iface.Usage } else { 0 }); Pid = $iface.Pid
                        InLen = $iface.InLen; OutLen = $iface.OutLen }
                    $contexts += [pscustomobject]@{ Dev = $dev; ReportId = $rid; DevIdx = $didx
                        FeatureIdx = $idx; Iface = $deviceIface }
                    if (-not $All -and (Get-DeviceRank $deviceIface.UsagePage $deviceIface.Usage $deviceIface.Product) -lt 10) {
                        $preferred = $true; break
                    }
                }
                if ($didx -eq 255) { break }
            }
            if ($preferred) { break }
        }
        $contexts = @($contexts | Sort-Object { Get-DeviceRank $_.Iface.UsagePage $_.Iface.Usage $_.Iface.Product })
        if (-not $All -and $contexts.Count -gt 1) { $contexts = @($contexts[0]) }
        foreach ($o in $opened) {
            $retained = $false
            foreach ($c in $contexts) {
                if ([object]::ReferenceEquals($c.Dev, $o.Dev)) { $retained = $true; break }
            }
            if (-not $retained) { $o.Dev.Close() }
        }
        $opened = @()
        if ($useCache -and $contexts.Count) { Save-CachedDevice $contexts[0] }
        return $contexts
    } catch { Close-MxDevices $opened; throw }
}

function Get-MxStatus {
    param($Ctx, [switch]$WithStatus)

    $transport = if ($Ctx.DevIdx -eq 0xFF) { 'direct (BT/USB)' } else { 'receiver' }
    $o = [ordered]@{
        product = $Ctx.Iface.Product
        transport = $transport
        device_index = $Ctx.DevIdx
        report_id = $Ctx.ReportId
        feature_index = $Ctx.FeatureIdx
    }
    $h = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $Ctx.FeatureIdx 0
    if ($h) { $o.hosts = $h[4]; $o.channel = $h[5] + 1 }

    if ($WithStatus) {
        foreach ($fid in 0x1004, 0x1000) {
            $idx = Resolve-MxFeature $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $fid
            if (-not $idx) { continue }
            $function = if ($fid -eq 0x1004) { 1 } else { 0 }
            $r = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $idx $function
            if ($r -and $r.Length -ge 7 -and $r[4] -gt 0 -and $r[4] -le 100) {
                $o.battery_percent = $r[4]
                $o.charging = $r[6] -in @(1,2)
                break
            }
        }
        $fw = Resolve-MxFeature $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx 0x0003
        if ($fw) {
            $r = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $fw 0
            if ($r) {
                $count = [int]$r[4]
                for ($entity = 0; $entity -lt $count; $entity++) {
                    $r = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $fw 1 ([byte[]]@($entity))
                    if ($r -and $r.Length -ge 12 -and ($r[4] -band 15) -eq 0) {
                        $o.firmware = '{0:X2}.{1:X2}' -f $r[8], $r[9]
                        $build = ([int]$r[10] -shl 8) -bor $r[11]
                        if ($build) { $o.firmware += '.B{0:X4}' -f $build }
                        break
                    }
                }
            }
        }
    }
    return [pscustomobject]$o
}

function Show-MxHuman {
    param($Report)
    'device     : {0}' -f $Report.product
    'transport  : {0}  index=0x{1:x2}  report=0x{2:x2}' -f `
        $Report.transport, $Report.device_index, $Report.report_id
    'ChangeHost : feature index 0x{0:x2}' -f $Report.feature_index
    if ($Report.PSObject.Properties.Name -contains 'hosts') {
        'channels   : {0}, currently on {1}' -f $Report.hosts, $Report.channel
    }
    if ($Report.PSObject.Properties.Name -contains 'battery_percent') {
        $state = if ($Report.charging) { 'charging' } else { 'discharging' }
        'battery    : {0}% ({1})' -f $Report.battery_percent, $state
    }
    if ($Report.PSObject.Properties.Name -contains 'firmware') {
        'firmware   : {0}' -f $Report.firmware
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Switch {
    param([object[]]$Contexts, [int]$TargetChannel, [int]$Attempts = 4)

    $results = @(foreach ($ctx in $Contexts) {
        $current = Invoke-HidppCall $ctx.Dev $ctx.ReportId $ctx.DevIdx $ctx.FeatureIdx 0
        [pscustomobject]@{
            Context = $ctx
            Frame = New-HidppFrame $ctx.ReportId $ctx.DevIdx $ctx.FeatureIdx 1 ([byte[]]@($TargetChannel - 1))
            Switched = $current -and $current.Length -ge 6 -and ($current[5] + 1) -eq $TargetChannel
            Written = $false
            OtherChannel = $null
        }
    })
    $pending = @($results | Where-Object { -not $_.Switched })
    for ($attempt = 1; $attempt -le $Attempts -and $pending.Count -gt 0; $attempt++) {
        Write-Verbose "switch attempt $attempt on $($pending.Count) device(s)"
        $wroteAny = $false
        foreach ($result in $pending) {
            $written = $result.Context.Dev.Write($result.Frame)
            # A retry may be rejected because the previous write already switched hosts.
            $result.Written = $result.Written -or $written
            $wroteAny = $wroteAny -or $written
        }
        # Give every write time to land before checking any device.
        if ($wroteAny) { Start-Sleep -Milliseconds 250 }

        $presentPaths = $null
        $pending = @(foreach ($result in $pending) {
            # One final query can establish the channel even after rejected writes.
            if ($result.Written -or $attempt -eq $Attempts) {
                $ctx = $result.Context
                $outcome = ''
                $still = Invoke-HidppCall $ctx.Dev $ctx.ReportId $ctx.DevIdx $ctx.FeatureIdx 0 @() 250 ([ref]$outcome)
                if ($result.Written -and $outcome -in @('write-failed', 'read-failed') -and $ctx.DevIdx -eq 255) {
                    if ($null -eq $presentPaths) { $presentPaths = @(Get-MxInterfaces | ForEach-Object Path) }
                    if ($ctx.Iface.Path -notin $presentPaths) { $outcome = 'disconnected' }
                }
                $channelRead = if ($still -and $still.Length -ge 6 -and $still[5] -lt 3) { $still[5] + 1 }
                if ($channelRead -eq $TargetChannel -or
                    ($result.Written -and $outcome -in @('timeout', 'disconnected'))) {
                    $result.Switched = $true
                    continue
                }
                if ($attempt -eq $Attempts) { $result.OtherChannel = $channelRead }
                Write-Verbose "could not verify the switch ($outcome)"
            }
            $result
        })
        if ($attempt -lt $Attempts -and $pending.Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    }
    $results
}

function Get-SwitchExitCode {
    param([object[]]$Results, [switch]$QuietUnconfirmed)

    $pending = @($Results | Where-Object { -not $_.Switched })
    if ($pending.Count -eq 0) { return 0 }
    if ($QuietUnconfirmed -and -not ($pending | Where-Object OtherChannel)) { return 4 }
    if ($pending.Count -eq $Results.Count) { return 1 }
    return 3
}

if (-not $env:MXSWITCH_TEST) {

$modes = @(@($Info, $Status, $List, $Toggle) | Where-Object { $_ })
if ($modes.Count + [int]$PSBoundParameters.ContainsKey('Channel') -gt 1) {
    Write-MxError '-Info, -Status, -List and -Toggle are mutually exclusive'
    exit 2
}

if ($Edge) {
    if ($Channel -notin @(1,2,3)) {
        Write-MxError '-Edge requires an explicit -Channel 1, 2 or 3.'
        exit 2
    }
    $switchParams = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'Edge') { $switchParams[$key] = $PSBoundParameters[$key] }
    }
    $rightEdge = $Edge -eq 'Right'
    $samples = 0
    "Watching the $Edge edge for channel $Channel. Press Ctrl+C to stop."
    while ($true) {
        # Start unarmed so a pointer left at the edge cannot switch back on arrival.
        if ([MxEdge]::Poll($rightEdge, [ref]$samples)) {
            & $PSCommandPath @switchParams
        }
        Start-Sleep -Milliseconds 50
    }
}

if ($List) {
    $found = [Hid]::Enumerate($VID)
    if (-not $found) { 'No Logitech vendor HID collections found.'; exit 1 }
    'usagePage:usage   pid    in  out  product'
    $found | ForEach-Object {
        '   {0:x4}:{1:x4}     {2:x4}  {3,3} {4,4}  {5}' -f `
            $_.UsagePage, $_.Usage, $_.Pid, $_.InLen, $_.OutLen, $_.Product
    }
    exit 0
}

if ($Config -and -not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    Write-MxError "Config file not found: $Config"; exit 2
}
$cfg = Get-MxConfig -Path $(if ($Config) { $Config } else { $ConfigFile })
Write-Verbose "config: $(if ($Config) { $Config } else { $ConfigFile })"
$problems = @(Test-MxConfig $cfg)
if ($problems.Count) { Write-MxError ("Invalid config: " + ($problems -join '; ')); exit 2 }
$wantAll = $All -or $cfg.device -eq 'all'

# Union of -Name and the config `name` list.
$cfgNames = @()
if ($cfg.name) {
    $cfgNames = @($cfg.name -split ',' | ForEach-Object { "$_".Trim() } |
                  Where-Object { $_ })
}
$nameFilter = @(@($Name) + $cfgNames | Where-Object { $_ })

if (-not $Toggle -and -not $Info -and -not $Status -and -not $Channel) {
    Write-MxError 'Give -Channel 1..3, -Info, -Status, -Toggle or -List'; exit 2
}
if (-not $Toggle -and -not $Info -and -not $Status -and $Channel -notin @(1,2,3)) {
    Write-MxError 'Channel must be 1, 2 or 3'; exit 2
}

$found = @(Find-MxDevices -All:$wantAll -Names $nameFilter)
if ($found.Count -eq 0) {
    Write-MxError ('No Logitech device supporting ChangeHost found. Click the mouse ' +
                   'to wake it, then retry. Run with -List to see what enumerated, ' +
                   'or -Verbose to watch the probe.')
    exit 1
}

if ($Info -or $Status) {
    $reports = @($found | ForEach-Object { Get-MxStatus $_ -WithStatus:$Status })
    if ($Json) {
        ConvertTo-Json -InputObject @($reports) -Depth 4
    } else {
        for ($i = 0; $i -lt $reports.Count; $i++) {
            if ($i) { '' }
            Show-MxHuman $reports[$i]
        }
    }
    Close-MxDevices $found
    exit 0
}

if ($Toggle) {
    $h = Invoke-HidppCall $found[0].Dev $found[0].ReportId $found[0].DevIdx `
                          $found[0].FeatureIdx 0
    if (-not $h) {
        Write-MxError 'Could not read the current channel.'
        Close-MxDevices $found
        exit 1
    }
    $current = $h[5] + 1
    if ($current -eq $cfg.channel_a)     { $Channel = $cfg.channel_b }
    elseif ($current -eq $cfg.channel_b) { $Channel = $cfg.channel_a }
    else {
        Write-MxError ("Current channel $current is not in the configured pair " +
                       "$($cfg.channel_a),$($cfg.channel_b). Refusing to guess.")
        Close-MxDevices $found
        exit 1
    }
}

if ($Channel -lt 1 -or $Channel -gt 3) {
    Write-MxError 'Channel must be 1, 2 or 3'
    Close-MxDevices $found
    exit 2
}

if ($DryRun) {
    foreach ($c in $found) {
        $frame = New-HidppFrame $c.ReportId $c.DevIdx $c.FeatureIdx 1 ([byte[]]@($Channel - 1))
        '{0}: switch to channel {1} -> {2}' -f $c.Iface.Product, $Channel, (Format-MxHex $frame)
    }
    Close-MxDevices $found
    exit 0
}

<#
    setCurrentHost never replies - the link is torn down as part of executing it.
    That makes "did it work?" awkward: a write that returns cleanly proves only
    that the driver accepted the buffer, not that the device acted on it. If the
    process exits here, the handle closes and a report still in flight can be
    lost, which is why a plain write-and-exit succeeds only intermittently.

    A switch usually stops replies on this host. A device that keeps answering
    can report its active channel directly.
#>

"Switching to channel $Channel ..."
try {
    $results = @(Invoke-Switch $found $Channel)
} finally {
    Close-MxDevices $found
}

foreach ($result in $results) {
    $product = $result.Context.Iface.Product
    if ($result.Switched) {
        "  {0}: command sent" -f $product
    } elseif ($result.OtherChannel) {
        Write-MxError ("  {0}: still on channel {1}, expected {2}." -f $product, $result.OtherChannel, $Channel)
    } else {
        Write-Verbose ("  {0}: could not confirm the switch to channel {1}." -f $product, $Channel)
    }
}

exit (Get-SwitchExitCode $results -QuietUnconfirmed:$QuietUnconfirmed)

}  # end if (-not $env:MXSWITCH_TEST)
