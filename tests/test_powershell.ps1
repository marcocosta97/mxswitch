<#
    Hardware-free tests for windows/mxswitch.ps1, run with Pester 5.

        Invoke-Pester tests/test_powershell.ps1

    The implementation is dot-sourced with MXSWITCH_TEST set so its main body
    (Add-Type, device scanning) is skipped and the pure helpers are reachable.
#>

$env:MXSWITCH_TEST = '1'
. (Join-Path $PSScriptRoot '..' 'windows' 'mxswitch.ps1')

Describe 'New-HidppFrame' {
    It 'encodes a long root getFeature frame' {
        $frame = New-HidppFrame 17 255 0 0 ([byte[]]@(0x18, 0x14, 0x00))
        (Format-Hex $frame) | Should -Be '11ff000a18140000000000000000000000000000'
    }
    It 'encodes a short root getFeature frame' {
        $frame = New-HidppFrame 16 255 0 0 ([byte[]]@(0x18, 0x14, 0x00))
        (Format-Hex $frame) | Should -Be '10ff000a181400'
    }
    It 'encodes getHostInfo long' {
        (Format-Hex (New-HidppFrame 17 255 10 0)) |
            Should -Be '11ff0a0a00000000000000000000000000000000'
    }
    It 'encodes setCurrentHost channel 2' {
        (Format-Hex (New-HidppFrame 17 255 10 1 ([byte[]]@(1)))) |
            Should -Be '11ff0a1a01000000000000000000000000000000'
    }
    It 'encodes a receiver slot 2 switch' {
        (Format-Hex (New-HidppFrame 17 2 10 1 ([byte[]]@(0)))) |
            Should -Be '11020a1a00000000000000000000000000000000'
    }
    It 'rejects an oversized short frame' {
        { New-HidppFrame 16 255 0 0 ([byte[]]@(0, 0, 0, 0, 0, 0, 0, 0)) } |
            Should -Throw
    }
}

Describe 'Get-ReplyVerdict' {
    It 'matches a getHostInfo reply' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0x0A,0x0A,3,1,0)) 255 10 |
            Should -Be 'match'
    }
    It 'ignores another feature notification' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0x05,0x0A,0,0)) 255 10 |
            Should -Be 'ignore'
    }
    It 'ignores another device' {
        Get-ReplyVerdict ([byte[]]@(0x11,0x01,0x0A,0x0A,3,1)) 255 10 |
            Should -Be 'ignore'
    }
    It 'ignores another software id' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0x0A,0x1B,3,1)) 255 10 |
            Should -Be 'ignore'
    }
    It 'flags a HID++ 2.0 error' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0xFF,0x0A,0,0)) 255 10 |
            Should -Be 'error'
    }
    It 'flags a HID++ 1.0 error' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0x8F,0x0A,0,0)) 255 10 |
            Should -Be 'error'
    }
    It 'flags a short reply' {
        Get-ReplyVerdict ([byte[]]@(0x11,0xFF,0x0A)) 255 10 |
            Should -Be 'too_short'
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
        $cfg = Get-MxConfig -Path (Join-Path $env:TEMP 'mxswitch-does-not-exist')
        $cfg.channel_a | Should -Be 1
        $cfg.channel_b | Should -Be 2
        $cfg.device | Should -Be 'primary'
    }
    It 'parses values, comments and junk' {
        $path = Join-Path $env:TEMP 'mxswitch-test-config'
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
