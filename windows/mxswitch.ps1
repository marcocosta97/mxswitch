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

    Exit codes: 0 ok, 1 device not found, 2 bad usage, 3 partial -All failure.
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
    [string[]]$Name,

    # Skip the cached device paths and force a full rescan.
    [switch]$NoCache
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
    param([byte[]]$Reply, [int]$DevIdx, [int]$FeatureIdx)

    if ($null -eq $Reply -or $Reply.Length -lt 5) { return 'too_short' }
    if ($Reply[1] -ne $DevIdx) { return 'ignore' }
    if ($Reply[2] -eq 0xFF -or $Reply[2] -eq 0x8F) { return 'error' }  # HID++ error
    if ($Reply[2] -ne $FeatureIdx) { return 'ignore' }                 # notification
    if (($Reply[3] -band 0x0F) -ne $SW_ID) { return 'ignore' }
    return 'match'
}

function Get-MxConfig {
    param([string]$Path = $ConfigFile)

    $cfg = [ordered]@{ channel_a = 1; channel_b = 2; device = 'primary'; name = '' }
    if ($Path -and (Test-Path $Path)) {
        foreach ($line in Get-Content $Path) {
            $clean = ($line -split '#', 2)[0].Trim()
            if (-not $clean) { continue }
            $parts = $clean -split '=', 2
            if ($parts.Count -lt 2) { continue }
            $key = $parts[0].Trim().ToLowerInvariant()
            $value = $parts[1].Trim()
            switch ($key) {
                'channel_a' { if ($value -match '^[123]$') { $cfg.channel_a = [int]$value } }
                'channel_b' { if ($value -match '^[123]$') { $cfg.channel_b = [int]$value } }
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
    if ($Config.channel_a -eq $Config.channel_b) {
        $problems += 'channel_a and channel_b must differ'
    }
    if ($Config.device -notin @('primary', 'all')) {
        $problems += 'device must be primary or all'
    }
    return $problems
}

function Format-Hex {
    param([byte[]]$Bytes)
    ($Bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# Device enumeration and the C# helper are only needed when the script actually
# runs; keeping them behind this guard lets tests dot-source the pure helpers.
if (-not $env:MXSWITCH_TEST) {

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.IO;
using System.Threading.Tasks;

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
        if (outLen <= 0) return false;
        var buf = new byte[outLen];
        Array.Copy(frame, buf, Math.Min(frame.Length, outLen));
        try {
            stream.Write(buf, 0, outLen);
            stream.Flush();
            return true;
        } catch (IOException)          { return false; }
          catch (UnauthorizedAccessException) { return false; }
    }

    // A synchronous read on a device with nothing to say never returns, so this
    // races the read against a timer and cancels it on timeout. The aborted read
    // must be drained before returning: FileStream serialises async operations,
    // so a still-pending read would block every later ReadAsync until it lands.
    public byte[] Read(int timeoutMs) {
        if (inLen <= 0) return new byte[0];
        var buf = new byte[inLen];
        try {
            var task = stream.ReadAsync(buf, 0, inLen);
            if (Task.WaitAny(new Task[] { task }, timeoutMs) != 0) {
                CancelIoEx(handle, IntPtr.Zero);
                try { task.Wait(1000); } catch (Exception) { }
                return new byte[0];
            }
            if (task.IsFaulted || task.Result <= 0) return new byte[0];
            var outb = new byte[task.Result];
            Array.Copy(buf, outb, task.Result);
            return outb;
        } catch (Exception) { return new byte[0]; }
    }

    public void Close() { try { stream.Dispose(); } catch {} }
}
'@

function Invoke-HidppCall {
    param($Dev, [int]$ReportId, [int]$DevIdx, [int]$FeatureIdx, [int]$Function,
          [byte[]]$Params = @(), [int]$TimeoutMs = 400)

    $frame = New-HidppFrame $ReportId $DevIdx $FeatureIdx $Function $Params
    if (-not $Dev.Write($frame)) { return $null }   # collection rejected it

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $r = $Dev.Read(100)
        $verdict = Get-ReplyVerdict -Reply $r -DevIdx $DevIdx -FeatureIdx $FeatureIdx
        if ($verdict -eq 'match') { return $r }
        if ($verdict -eq 'error') { return $null }
    }
    return $null
}

function Resolve-MxFeature {
    param($Dev, [int]$ReportId, [int]$DevIdx, [int]$FeatureId)
    $probe = [byte[]]@(($FeatureId -shr 8) -band 0xFF, $FeatureId -band 0xFF, 0)
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

<#
    Discovery costs a round trip per candidate collection and device index, so
    the resolved answer is cached. This is purely a latency win: a cached path
    for a device that has since gone to sleep will not open, and we fall back to
    a full scan. The cache is validated on every use rather than trusted, so a
    firmware update that moves the feature index self-corrects.
#>
function Get-CachedDevices {
    if ($NoCache -or -not (Test-Path $CacheFile)) { return @() }
    try { $entries = Get-Content $CacheFile -Raw | ConvertFrom-Json } catch { return @() }
    if ($null -eq $entries) { return @() }
    if ($entries -isnot [System.Collections.IEnumerable] -or
        $entries -is [string]) {
        $entries = @($entries)
    }

    $valid = @()
    foreach ($c in $entries) {
        $iface = New-Object 'Hid+Iface'
        $iface.Path = $c.Path; $iface.Product = $c.Product
        $iface.UsagePage = $c.UsagePage; $iface.Usage = $c.Usage; $iface.Pid = $c.Pid
        $iface.InLen = $c.InLen; $iface.OutLen = $c.OutLen

        try { $dev = New-Object Hid $iface } catch {
            foreach ($v in $valid) { $v.Dev.Close() }
            return @()
        }

        # Confirm the cached feature index still resolves to ChangeHost. Only
        # accept the report ID that actually produced the reply.
        $rid = $c.ReportId
        $r = Invoke-HidppCall $dev $rid $c.DevIdx 0 0 ([byte[]]@(0x18, 0x14, 0x00)) 250
        if (-not $r) {
            $alt = if ($rid -eq 0x11) { 0x10 } else { 0x11 }
            $r = Invoke-HidppCall $dev $alt $c.DevIdx 0 0 ([byte[]]@(0x18, 0x14, 0x00)) 250
            if ($r) { $rid = $alt }
        }
        if ($r -and $r[4] -eq $c.FeatureIdx -and $r[4] -ne 0) {
            $valid += [pscustomobject]@{ Dev = $dev; ReportId = $rid; DevIdx = $c.DevIdx
                                         FeatureIdx = $c.FeatureIdx; Iface = $iface }
        } else {
            $dev.Close()
            foreach ($v in $valid) { $v.Dev.Close() }
            return @()          # one stale entry invalidates the cache
        }
    }
    return $valid
}

function Save-CachedDevices {
    param($Contexts)
    if ($NoCache) { return }
    try {
        $dir = Split-Path $CacheFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $entries = $Contexts | ForEach-Object {
            [pscustomobject]@{
                Path = $_.Iface.Path; Product = $_.Iface.Product
                UsagePage = $_.Iface.UsagePage; Usage = $_.Iface.Usage
                Pid = $_.Iface.Pid; InLen = $_.Iface.InLen; OutLen = $_.Iface.OutLen
                DevIdx = $_.DevIdx; ReportId = $_.ReportId; FeatureIdx = $_.FeatureIdx
            }
        }
        ConvertTo-Json -InputObject @($entries) | Set-Content $CacheFile
    } catch { Write-Verbose 'could not write cache' }
}

# Returns an array of contexts. With -All, every unique ChangeHost device.
function Find-MxDevices {
    param([switch]$All, [string[]]$Names)

    $cached = @(Get-CachedDevices)
    # A name filter cannot be answered from the cache, which may only hold the
    # primary device, so rescan when one is set.
    if ($cached.Count -gt 0 -and $Names -and $Names.Count -gt 0) {
        foreach ($c in $cached) { $c.Dev.Close() }
        $cached = @()
    }
    if ($cached.Count -gt 0) {
        # A cache written by a non-All run may hold only the primary device, so
        # never satisfy -All from it. Rescan to find every device.
        if ($All) {
            foreach ($c in $cached) { $c.Dev.Close() }
        } elseif ((Get-DeviceRank $cached[0].Iface.UsagePage `
                    $cached[0].Iface.Usage $cached[0].Iface.Product) -lt 20) {
            # Prefer a live mouse over a cached keyboard.
            Write-Verbose 'using cached device'
            for ($i = 1; $i -lt $cached.Count; $i++) { $cached[$i].Dev.Close() }
            return @($cached[0])
        } else {
            foreach ($c in $cached) { $c.Dev.Close() }
        }
    }

    $ifaces = [Hid]::Enumerate($VID) |
        Where-Object { Test-MxName $_.Product $Names } |
        Sort-Object { Get-DeviceRank $_.UsagePage $_.Usage $_.Product }

    $contexts = @()
    $seen = @{}
    foreach ($iface in $ifaces) {
        if (-not $All -and $contexts.Count -gt 0) { break }
        Write-Verbose ("probing {0:x4}:{1:x4} out={2} {3}" -f `
            $iface.UsagePage, $iface.Usage, $iface.OutLen, $iface.Product)

        try { $dev = New-Object Hid $iface } catch { continue }

        # Try the report ID whose frame size matches this collection first; the
        # other is attempted only in case one collection declares both.
        $reportIds = @(0x11, 0x10) | Sort-Object `
            @{ Expression = { if ($FRAME_LEN[[int]$_] -eq $iface.OutLen) { 0 } else { 1 } } }

        $matched = $false
        foreach ($didx in $DEVICE_INDICES) {
            if ($matched) { break }
            foreach ($rid in $reportIds) {
                $r = Invoke-HidppCall $dev $rid $didx 0 0 ([byte[]]@(0x18, 0x14, 0x00)) 250
                if ($r -and $r[4] -ne 0) {
                    $key = "$($iface.Product.ToLowerInvariant())|$didx"
                    if (-not $seen.ContainsKey($key)) {
                        Write-Verbose ("matched index=0x{0:x2} report=0x{1:x2}" -f $didx, $rid)
                        $seen[$key] = $true
                        $contexts += [pscustomobject]@{ Dev = $dev; ReportId = $rid
                                                        DevIdx = $didx; FeatureIdx = $r[4]
                                                        Iface = $iface }
                    } else {
                        $dev.Close()
                    }
                    $matched = $true
                    break
                }
            }
        }
        if (-not $matched) { $dev.Close() }
    }
    if ($contexts.Count -gt 0) { Save-CachedDevices $contexts }
    return $contexts
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
            $r = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $idx 0
            if ($r) {
                $o.battery_percent = $r[4]
                $o.charging = [bool]($r[5] -band 0x01)
                break
            }
        }
        $fw = Resolve-MxFeature $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx 0x0003
        if ($fw) {
            $r = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx $fw 0
            if ($r -and $r[4] -gt 0 -and ($r[6] -or $r[7])) {
                $o.firmware = "$($r[6]).$($r[7])"
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

$modes = @(@($Info, $Status, $List, $Toggle) | Where-Object { $_ })
if ($modes.Count -gt 1) {
    Write-MxError '-Info, -Status, -List and -Toggle are mutually exclusive'
    exit 2
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

$cfg = Get-MxConfig -Path $(if ($Config) { $Config } else { $ConfigFile })
if ($Config) { Write-Verbose "config: $Config" }
$wantAll = $All -or $cfg.device -eq 'all'

# Union of -Name and the config `name` list.
$cfgNames = @()
if ($cfg.name) {
    $cfgNames = @($cfg.name -split ',' | ForEach-Object { "$_".Trim() } |
                  Where-Object { $_ })
}
$nameFilter = @(@($Name) + $cfgNames | Where-Object { $_ })

if ($Toggle) {
    $problems = @(Test-MxConfig $cfg)
    if ($problems.Count -gt 0) {
        Write-MxError ("Cannot toggle: " + ($problems -join '; '))
        exit 2
    }
} elseif (-not $Info -and -not $Status -and -not $Channel) {
    Write-MxError 'Give -Channel 1..3, -Info, -Status, -Toggle or -List'
    exit 2
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
    foreach ($c in $found) { $c.Dev.Close() }
    exit 0
}

if ($Toggle) {
    $h = Invoke-HidppCall $found[0].Dev $found[0].ReportId $found[0].DevIdx `
                          $found[0].FeatureIdx 0
    if (-not $h) {
        Write-MxError 'Could not read the current channel.'
        foreach ($c in $found) { $c.Dev.Close() }
        exit 1
    }
    $current = $h[5] + 1
    if ($current -eq $cfg.channel_a)     { $Channel = $cfg.channel_b }
    elseif ($current -eq $cfg.channel_b) { $Channel = $cfg.channel_a }
    else {
        Write-MxError ("Current channel $current is not in the configured pair " +
                       "$($cfg.channel_a),$($cfg.channel_b). Refusing to guess.")
        foreach ($c in $found) { $c.Dev.Close() }
        exit 1
    }
}

if ($Channel -lt 1 -or $Channel -gt 3) {
    Write-MxError 'Channel must be 1, 2 or 3'
    foreach ($c in $found) { $c.Dev.Close() }
    exit 2
}

if ($DryRun) {
    foreach ($c in $found) {
        $frame = New-HidppFrame $c.ReportId $c.DevIdx $c.FeatureIdx 1 ([byte[]]@($Channel - 1))
        '{0}: switch to channel {1} -> {2}' -f $c.Iface.Product, $Channel, (Format-Hex $frame)
    }
    foreach ($c in $found) { $c.Dev.Close() }
    exit 0
}

<#
    setCurrentHost never replies - the link is torn down as part of executing it.
    That makes "did it work?" awkward: a write that returns cleanly proves only
    that the driver accepted the buffer, not that the device acted on it. If the
    process exits here, the handle closes and a report still in flight can be
    lost, which is why a plain write-and-exit succeeds only intermittently.

    So verify by absence. After the switch the device should stop answering; if
    it still replies to getHostInfo, the frame did not land and we try again.
#>
function Invoke-Switch {
    param($Ctx, [int]$TargetChannel, [int]$Attempts = 4)

    $frame = New-HidppFrame $Ctx.ReportId $Ctx.DevIdx $Ctx.FeatureIdx 1 ([byte[]]@($TargetChannel - 1))
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Verbose "switch attempt $attempt"
        if ($Ctx.Dev.Write($frame)) {
            Start-Sleep -Milliseconds 250
            $still = Invoke-HidppCall $Ctx.Dev $Ctx.ReportId $Ctx.DevIdx `
                                      $Ctx.FeatureIdx 0 @() 250
            if (-not $still) { return $true }        # gone: it worked
            Write-Verbose 'device still responding, retrying'
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

"Switching to channel $Channel ..."
$failures = 0
foreach ($c in $found) {
    if (Invoke-Switch $c $Channel) {
        "  {0}: command sent" -f $c.Iface.Product
    } else {
        Write-MxError ("  {0}: the device did not leave this host. It may be asleep, or the target channel may be unpaired." -f $c.Iface.Product)
        $failures++
    }
}
foreach ($c in $found) { $c.Dev.Close() }

if ($failures -eq 0) { exit 0 }
if ($failures -eq $found.Count) { exit 1 }
Write-MxError "$failures of $($found.Count) devices failed."
exit 3

}  # end if (-not $env:MXSWITCH_TEST)
