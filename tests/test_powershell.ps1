<#
    Hardware-free tests for windows/mxswitch.ps1, run with Pester 5.

        Invoke-Pester tests/test_powershell.ps1

    The implementation is dot-sourced with MXSWITCH_TEST set so its main body
    (Add-Type, device scanning) is skipped and the pure helpers are reachable.
#>

BeforeAll {
    $originalTestEnv = $env:MXSWITCH_TEST
    $originalLocalAppData = $env:LOCALAPPDATA
    $env:MXSWITCH_TEST = '1'
    $env:LOCALAPPDATA = $TestDrive
    . (Join-Path $PSScriptRoot '../windows/mxswitch.ps1')
    $source = Get-Content (Join-Path $PSScriptRoot '../windows/mxswitch.ps1') -Raw
    $native = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
    if (-not $native.Success) { throw 'Native HID helper source not found' }
    Add-Type -TypeDefinition $native.Groups[1].Value
    $fixtures = Get-Content (Join-Path $PSScriptRoot 'fixtures/frames.json') -Raw | ConvertFrom-Json
    function New-TestInterface {
        param([string]$Path, [hashtable]$Slots, [string]$Product = 'USB Receiver')
        [pscustomobject]@{ Path=$Path; Slots=$Slots; Product=$Product; Pid=1; UsagePage=0xff00; Usage=1; InLen=20; OutLen=20 }
    }
    function New-TestTransport {
        param($Iface)
        $dev = [pscustomobject]@{ Slots=$Iface.Slots; Writes=(New-Object 'System.Collections.Generic.List[object]'); Pending=$null; Closed=0 }
        $dev | Add-Member ScriptMethod Write {
            param([byte[]]$Frame)
            $this.Writes.Add($Frame.Clone())
            $profile = $this.Slots[[int]$Frame[1]]
            $r = New-Object byte[] 20
            $r[0]=17; $r[1]=$Frame[1]; $r[2]=$Frame[2]; $r[3]=$Frame[3]
            $function = $Frame[3] -shr 4
            if (-not $profile) {
                $r[0]=16; $r[2]=255; $r[3]=$Frame[2]; $r[4]=$Frame[3]; $r[5]=9
            } elseif ($Frame[2] -eq 0) {
                $feature = ([int]$Frame[4] -shl 8) -bor $Frame[5]
                $idx = switch ($feature) { 0x1814 {10} 5 {5} 3 {3} 0x1004 { if (-not $profile.Legacy) {6} else {0} } 0x1000 {7} default {0} }
                $r[4]=$idx
            } elseif ($Frame[2] -eq 5) {
                $name=[Text.Encoding]::UTF8.GetBytes($profile.Name)
                if ($function -eq 0) { $r[4]=$name.Length }
                else { [Array]::Copy($name,[int]$Frame[4],$r,4,[Math]::Min(16,$name.Length-$Frame[4])) }
            } elseif ($Frame[2] -eq 3) {
                if ($function -eq 0) {
                    $r[4]=2; $unit=[uint32]$profile.Unit
                    for ($i=0; $i -lt 4; $i++) { $r[5+$i]=($unit -shr (24-8*$i)) -band 255 }
                } else {
                    $r[4]=if ($Frame[4] -eq 0) {1} else {0}
                    $r[8]=0x12; $r[9]=0x34; $r[10]=0xab; $r[11]=0xcd
                }
            } elseif ($Frame[2] -in @(6,7)) {
                $r[4]=if ($Frame[2] -eq 6 -and $function -eq 0) {2} else {88}
                $r[5]=80; $r[6]=if ($profile.ContainsKey('Charge')) {$profile.Charge} else {1}
            } elseif ($Frame[2] -eq 10) {
                if ($function -eq 1) { $profile.Channel=[int]$Frame[4] }
                $r[4]=3; $r[5]=if ($profile.ContainsKey('Channel')) {$profile.Channel} else {0}
            }
            $this.Pending=$r
            return $true
        }
        $dev | Add-Member ScriptMethod Read { param($TimeoutMs) $r=$this.Pending; $this.Pending=$null; return ,$r }
        $dev | Add-Member ScriptMethod Close { $this.Closed++ }
        return $dev
    }

}
AfterAll {
    $env:MXSWITCH_TEST = $originalTestEnv
    $env:LOCALAPPDATA = $originalLocalAppData
}

Describe 'Shared protocol cases' {
    It 'encodes all shared frames' {
        $fixtures.frames.Count | Should -BeGreaterThan 0
        foreach ($f in $fixtures.frames) {
            $frame = New-HidppFrame $f.report_id $f.device_index $f.feature_index $f.function ([byte[]]$f.params)
            (Format-Hex $frame) | Should -Be $f.hex -Because $f.name
        }
    }
    It 'classifies all shared replies' {
        $fixtures.replies.Count | Should -BeGreaterThan 0
        foreach ($r in $fixtures.replies) {
            $bytes = [byte[]]@(for ($i=0; $i -lt $r.hex.Length; $i+=2) { [Convert]::ToByte($r.hex.Substring($i,2),16) })
            $function = if ($r.PSObject.Properties.Name -contains 'function') { $r.function } else { 0 }
            Get-ReplyVerdict $bytes $r.device_index $r.feature_index $function | Should -Be $r.outcome -Because $r.name
        }
    }
    It 'rejects an oversized short frame' {
        { New-HidppFrame 16 255 0 0 ([byte[]]@(1,2,3,4)) } | Should -Throw
    }
}

Describe 'Test-MxName' {
    It 'matches everything with no filter' {
        (Test-MxName 'MX Master 3S' @()) | Should -Be $true
        (Test-MxName 'MX Master 3S' $null) | Should -Be $true
    }
    It 'matches a case-insensitive substring' {
        (Test-MxName 'MX Keys S' @('keys')) | Should -Be $true
        (Test-MxName 'mx keys s' @('KEYS')) | Should -Be $true
    }
    It 'matches when any of several substrings is present' {
        (Test-MxName 'MX Master 3S' @('nope', 'master')) | Should -Be $true
    }
    It 'rejects a non-matching name' {
        (Test-MxName 'MX Master 3S' @('keys')) | Should -Be $false
        (Test-MxName '' @('keys')) | Should -Be $false
    }
}

Describe 'Resolve-MxProduct' {
    It 'keeps a real product string' {
        (Resolve-MxProduct 'MX Keys S' 0x1234) | Should -Be 'MX Keys S'
    }
    It 'names POP Icon Keys when the string is empty' {
        (Resolve-MxProduct '' 0xB38F) | Should -Be 'POP Icon Keys'
    }
    It 'leaves other unnamed devices empty' {
        (Resolve-MxProduct '' 0x1234) | Should -Be ''
    }
}

Describe 'Get-MxConfig' {
    It 'returns defaults when the file is missing' {
        $cfg = Get-MxConfig -Path (Join-Path $TestDrive 'mxswitch-does-not-exist')
        $cfg.channel_a | Should -Be 1
        $cfg.channel_b | Should -Be 2
        $cfg.device | Should -Be 'primary'
    }
    It 'parses values, comments and junk' {
        $path = Join-Path $TestDrive 'mxswitch-test-config'
        @('# comment', 'channel_a = 3', '', 'junk', 'channel_b=1', 'device = all',
          'name = MX Keys, MX Master') | Set-Content $path
        try {
            $cfg = Get-MxConfig -Path $path
            $cfg.channel_a | Should -Be 3
            $cfg.channel_b | Should -Be 1
            $cfg.device | Should -Be 'all'
            $cfg.name | Should -Be 'MX Keys, MX Master'
        } finally {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }
    It 'rejects a duplicate channel pair' {
        $cfg = [pscustomobject]@{ channel_a = 1; channel_b = 1; device = 'primary' }
        (Test-MxConfig $cfg) | Should -Contain 'channel_a and channel_b must differ'
    }
    It 'rejects an unknown device value' {
        $cfg = [pscustomobject]@{ channel_a = 1; channel_b = 2; device = 'nope' }
        (Test-MxConfig $cfg) | Should -Contain 'device must be primary or all'
    }
}


Describe 'Discovery through a simulated HID transport' {
    BeforeEach {
        Mock Get-CachedDevices { @() }
        Mock Save-CachedDevices { }
        $script:opened = New-Object 'System.Collections.Generic.List[object]'
        Mock Open-MxDevice { param($Iface) $dev=New-TestTransport $Iface; $script:opened.Add($dev); return $dev }
    }
    It 'enumerates all receiver slots and prefers the mouse' {
        $script:interfaces = @(New-TestInterface receiver @{1=@{Name='MX Keys S';Unit=1};2=@{Name='MX Master 3S';Unit=2}})
        Mock Get-MxInterfaces { $script:interfaces }
        $found=@(Find-MxDevices -All)
        $found.Count | Should -Be 2
        $found[0].DevIdx | Should -Be 2
        Close-MxDevices $found
        $script:opened[0].Closed | Should -Be 1
    }
    It 'filters peripheral names and reads name fragments' {
        $script:interfaces = @(New-TestInterface receiver @{1=@{Name='Logitech MX Keys S Keyboard';Unit=1};2=@{Name='MX Master 3S';Unit=2}})
        Mock Get-MxInterfaces { $script:interfaces }
        $found=@(Find-MxDevices -All -Names Keys)
        $found.Count | Should -Be 1
        $found[0].Iface.Product | Should -Be 'Logitech MX Keys S Keyboard'
        Close-MxDevices $found
    }
    It 'deduplicates collections without dropping another mouse of the same model' {
        $script:interfaces = @(
            New-TestInterface mouse-a-col1 @{255=@{Name='MX Master 3S';Unit=1}} 'MX Master 3S'
            New-TestInterface mouse-a-col2 @{255=@{Name='MX Master 3S';Unit=1}} 'MX Master 3S'
            New-TestInterface mouse-b @{255=@{Name='MX Master 3S';Unit=2}} 'MX Master 3S'
        )
        Mock Get-MxInterfaces { $script:interfaces }
        $found=@(Find-MxDevices -All)
        $found.Count | Should -Be 2
        Close-MxDevices $found
        foreach ($dev in $script:opened) { $dev.Closed | Should -Be 1 }
    }
    It 'keeps only the primary device without closing its shared handle' {
        $script:interfaces = @(New-TestInterface receiver @{1=@{Name='MX Keys S';Unit=1};2=@{Name='MX Master 3S';Unit=2}})
        Mock Get-MxInterfaces { $script:interfaces }
        $found=@(Find-MxDevices)
        $found.Count | Should -Be 1
        $found[0].DevIdx | Should -Be 2
        $found[0].Dev.Closed | Should -Be 0
        Close-MxDevices $found
    }
}

Describe 'Status and switch protocol' {
    BeforeEach {
        $iface=New-TestInterface mouse @{255=@{Name='Mouse';Unit=1}}
        $dev=New-TestTransport $iface
        $ctx=[pscustomobject]@{ Dev=$dev; Iface=$iface; DevIdx=255; ReportId=17; FeatureIdx=10 }
    }
    It 'reads unified battery state and the main firmware entity' {
        $status=Get-MxStatus $ctx -WithStatus
        $status.battery_percent | Should -Be 88
        $status.charging | Should -Be $true
        $status.firmware | Should -Be '12.34.BABCD'
        $calls=@($dev.Writes | Where-Object { $_[2] -eq 6 })
        ($calls[0][3] -shr 4) | Should -Be 1
    }
    It 'reads legacy battery charging from the status byte' {
        $dev.Slots[255].Legacy=$true; $dev.Slots[255].Charge=0
        $status=Get-MxStatus $ctx -WithStatus
        $status.battery_percent | Should -Be 88
        $status.charging | Should -Be $false
    }
    It 'accepts a channel that is already active without sending switch commands' {
        $dev.Slots[255].Channel=1
        Invoke-Switch $ctx 2 | Should -Be $true
        @($dev.Writes | Where-Object { ($_[3] -shr 4) -eq 1 }).Count | Should -Be 0
    }
    It 'accepts a device that still responds on the requested channel' {
        Invoke-Switch $ctx 2 | Should -Be $true
        $dev.Slots[255].Channel | Should -Be 1
    }
    It 'rotates request IDs' {
        Resolve-MxFeature $dev 17 255 0x1814 | Should -Be 10
        Resolve-MxFeature $dev 17 255 5 | Should -Be 5
        $dev.Writes[0][3] | Should -Not -Be $dev.Writes[1][3]
    }
    It 'rejects invalid configured channels rather than using defaults' {
        $path=Join-Path $TestDrive bad-config
        'channel_a=typo' | Set-Content $path
        $cfg=Get-MxConfig $path
        $cfg.channel_a | Should -Be 0
        @(Test-MxConfig $cfg).Count | Should -BeGreaterThan 0
    }
}
