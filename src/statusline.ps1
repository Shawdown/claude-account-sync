$dir = $env:CLAUDE_CONFIG_DIR
if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:USERPROFILE '.claude' }
$parts = @()
$labelPath = Join-Path $dir '.account-label'
if (Test-Path -LiteralPath $labelPath) { $parts += ([IO.File]::ReadAllText($labelPath)).Trim() }
try {
    $inputText = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($inputText)) {
        $data = ConvertFrom-Json -InputObject $inputText
        if ($data.model -and $data.model.display_name) { $parts += [string]$data.model.display_name }
    }
}
catch {
}
[Console]::Out.Write((($parts | Where-Object { $_ }) -join ' | '))
