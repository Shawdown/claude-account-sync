$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../src/lib.ps1')

$script:Failures = 0

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ceq $Actual) {
        Write-Host "PASS  $Name"
    }
    else {
        $script:Failures++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Parse([string]$Json) { return , (ConvertFrom-JsonText $Json) }

function Doc([string]$Json, [int]$Minute) {
    $doc = $null
    if ($Json) { $doc = Parse $Json }
    return @{ Doc = $doc; Time = ([datetime]'2026-01-01').AddMinutes($Minute) }
}

function Merge([string]$Base, $Docs) {
    $baseDoc = $null
    if ($Base) { $baseDoc = Parse $Base }
    return ConvertTo-CompactJson (Merge-SharedConfig $baseDoc $Docs)
}

$personal = '{"oauthAccount":{"emailAddress":"me@home"},"theme":"dark","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'

Assert-Equal '{"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}},"mcpServers":{"a":{"command":"a"}},"theme":"dark"}' `
    (Merge $null @((Doc $personal 1), (Doc $null 0))) 'first run takes shared keys from the existing account'

$base = '{"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}},"mcpServers":{"a":{"command":"a"}},"theme":"dark"}'
$org = '{"oauthAccount":{"emailAddress":"me@work"},"theme":"dark","mcpServers":{"a":{"command":"a"},"b":{"command":"b"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'

Assert-Equal '{"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}},"mcpServers":{"a":{"command":"a"},"b":{"command":"b"}},"theme":"dark"}' `
    (Merge $base @((Doc $personal 5), (Doc $org 1))) 'a server added in one account reaches the other even if that one is newer'

$personalRemoved = '{"theme":"dark","mcpServers":{},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'
$orgSame = '{"theme":"dark","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'

Assert-Equal '{"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}},"mcpServers":{},"theme":"dark"}' `
    (Merge $base @((Doc $personalRemoved 1), (Doc $orgSame 5))) 'a server removed in one account is removed everywhere'

$personalTools = '{"theme":"dark","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":["Bash(ls)"],"hasTrustDialogAccepted":true}}}'
$orgCost = '{"theme":"dark","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true,"lastCost":2}}}'

Assert-Equal '{"projects":{"C:/p":{"allowedTools":["Bash(ls)"],"hasTrustDialogAccepted":true,"lastCost":2}},"mcpServers":{"a":{"command":"a"}},"theme":"dark"}' `
    (Merge $base @((Doc $personalTools 1), (Doc $orgCost 2))) 'different changes to the same project are both kept'

$personalLight = '{"theme":"light","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'
$orgDaltonized = '{"theme":"dark-daltonized","mcpServers":{"a":{"command":"a"}},"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'

Assert-Equal '{"projects":{"C:/p":{"allowedTools":[],"hasTrustDialogAccepted":true}},"mcpServers":{"a":{"command":"a"}},"theme":"dark-daltonized"}' `
    (Merge $base @((Doc $personalLight 1), (Doc $orgDaltonized 2))) 'the same setting changed in both accounts takes the newest'

$casePaths = '{"projects":{"C:/p":{"a":1},"c:/p":{"a":2}}}'
Assert-Equal '{"projects":{"C:/p":{"a":1},"c:/p":{"a":2}}}' `
    (Merge $null @((Doc $casePaths 1))) 'project paths that differ only in case stay separate'

$shared = Parse '{"projects":{"C:/p":{}},"theme":"light"}'
$account = Parse '{"oauthAccount":{"emailAddress":"me@work"},"theme":"dark","verbose":true,"userID":"x"}'
Assert-Equal '{"oauthAccount":{"emailAddress":"me@work"},"theme":"light","userID":"x","projects":{"C:/p":{}}}' `
    (ConvertTo-CompactJson (Set-SharedConfig $account $shared)) 'account fields are kept and shared fields are replaced'

$sample = Parse '{"hooks":{"Stop":[{"command":"a && b <c> it''s"}]},"n":1.5,"e":[],"o":{},"t":true,"z":null}'
$pretty = Format-Json -Value $sample
Assert-Equal (ConvertTo-CompactJson $sample) (ConvertTo-CompactJson (Parse $pretty)) 'pretty output reads back the same'

$inner = Parse '{"x":[1,2]}'
$outer = New-Dict
$outer['wrapped'] = [psobject]$inner
$outer['list'] = @([psobject]'a', [psobject]2)
Assert-Equal '{"wrapped":{"x":[1,2]},"list":["a",2]}' (ConvertTo-CompactJson ([psobject]$outer)) 'wrapped PowerShell objects are written as plain JSON'

$tricky = Parse '{"s":"tab\there \"quoted\" back\\slash \\u0026 line\nend"}'
Assert-Equal (ConvertTo-CompactJson $tricky) (ConvertTo-CompactJson (Parse (ConvertTo-CompactJson $tricky))) 'escaped characters survive a round trip'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
