$script:SourceDir = $PSScriptRoot
$script:HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:InstallDir = Join-Path $script:HomeDir '.claude-account-sync'
$script:ConfigPath = Join-Path $script:InstallDir 'config.json'
$script:BasePath = Join-Path $script:InstallDir 'base.json'
$script:LogPath = Join-Path $script:InstallDir 'sync.log'
$script:BackupDir = Join-Path $script:InstallDir 'backups'
$script:ConflictDir = Join-Path $script:InstallDir 'conflicts'
$script:BinDir = Join-Path $script:InstallDir 'bin'
$script:BinPathEntry = '%USERPROFILE%\.claude-account-sync\bin'
$script:TaskName = 'Claude Account Sync'
$script:DesktopFiles = @('Switch to Personal.cmd', 'Switch to Org.cmd')
$script:LabelFile = '.account-label'
$script:ConflictRetentionDays = 30

$script:SharedKeyDepth = [ordered]@{
    projects                      = 2
    mcpServers                    = 1
    githubRepoPaths               = 1
    tipsHistory                   = 1
    hasCompletedOnboarding        = 0
    lastOnboardingVersion         = 0
    theme                         = 0
    editorMode                    = 0
    preferredNotifChannel         = 0
    autoCompactEnabled            = 0
    verbose                       = 0
    autoUpdates                   = 0
    shiftEnterKeyBindingInstalled = 0
    hasIdeOnboardingBeenShown     = 0
    bypassPermissionsModeAccepted = 0
}

$script:ExcludedNames = @(
    '.credentials.json', '.claude.json', $script:LabelFile,
    'statsig', 'telemetry', 'ide', 'debug', 'shell-snapshots', 'backups'
)
$script:ExcludedPatterns = @('*.lock', '.claude.json.*', '*.tmp', '*.tmp.*', '*.sync-tmp')

$script:JsonMode = $null
$script:Serializer = $null
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Initialize-Json {
    if ($null -ne $script:JsonMode) { return }
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $serializer.RecursionLimit = 1024
        $script:Serializer = $serializer
        $script:JsonMode = 'serializer'
    }
    catch {
        $script:JsonMode = 'native'
    }
}

function ConvertFrom-JsonText([string]$Text) {
    Initialize-Json
    if ($script:JsonMode -eq 'serializer') {
        return , $script:Serializer.DeserializeObject($Text)
    }
    return , (ConvertFrom-Json -InputObject $Text -AsHashtable)
}

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:ControlCharEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param($match)
    switch ([int][char]$match.Value) {
        8 { return '\b' }
        9 { return '\t' }
        10 { return '\n' }
        12 { return '\f' }
        13 { return '\r' }
        default { return '\u' + ([int][char]$match.Value).ToString('x4') }
    }
}

function Add-JsonString([System.Text.StringBuilder]$Builder, [string]$Text) {
    $escaped = $Text.Replace('\', '\\').Replace('"', '\"')
    $escaped = [regex]::Replace($escaped, '[\x00-\x1f]', $script:ControlCharEvaluator)
    [void]$Builder.Append('"').Append($escaped).Append('"')
}

function Add-JsonValue([System.Text.StringBuilder]$Builder, $Value, [string]$Indent, [bool]$Pretty) {
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [string] -or $Value -is [char]) { Add-JsonString $Builder ([string]$Value); return }
    if ($Value -is [bool]) {
        if ($Value) { [void]$Builder.Append('true') } else { [void]$Builder.Append('false') }
        return
    }
    $next = $Indent + '  '
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.get_Keys())
        if ($keys.Count -eq 0) { [void]$Builder.Append('{}'); return }
        [void]$Builder.Append('{')
        for ($i = 0; $i -lt $keys.Count; $i++) {
            if ($i -gt 0) { [void]$Builder.Append(',') }
            if ($Pretty) { [void]$Builder.Append("`n").Append($next) }
            Add-JsonString $Builder ([string]$keys[$i])
            if ($Pretty) { [void]$Builder.Append(': ') } else { [void]$Builder.Append(':') }
            Add-JsonValue $Builder ($Value[$keys[$i]]) $next $Pretty
        }
        if ($Pretty) { [void]$Builder.Append("`n").Append($Indent) }
        [void]$Builder.Append('}')
        return
    }
    if ($Value -is [System.Collections.IList]) {
        if ($Value.get_Count() -eq 0) { [void]$Builder.Append('[]'); return }
        [void]$Builder.Append('[')
        for ($i = 0; $i -lt $Value.get_Count(); $i++) {
            if ($i -gt 0) { [void]$Builder.Append(',') }
            if ($Pretty) { [void]$Builder.Append("`n").Append($next) }
            Add-JsonValue $Builder ($Value[$i]) $next $Pretty
        }
        if ($Pretty) { [void]$Builder.Append("`n").Append($Indent) }
        [void]$Builder.Append(']')
        return
    }
    if ($Value -is [double] -or $Value -is [single]) {
        [void]$Builder.Append(([double]$Value).ToString('R', $script:Invariant))
        return
    }
    if ($Value -is [decimal] -or $Value.GetType().IsPrimitive) {
        [void]$Builder.Append([Convert]::ToString($Value, $script:Invariant))
        return
    }
    Add-JsonString $Builder ([string]$Value)
}

function ConvertTo-CompactJson($Value) {
    $builder = New-Object System.Text.StringBuilder
    Add-JsonValue $builder $Value '' $false
    return $builder.ToString()
}

function Format-Json($Value) {
    $builder = New-Object System.Text.StringBuilder
    Add-JsonValue $builder $Value '' $true
    return $builder.ToString()
}

function New-Dict {
    return , (New-Object 'System.Collections.Generic.Dictionary[string,object]')
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return , (ConvertFrom-JsonText $text)
}

function Write-JsonFile([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (Format-Json -Value $Value) + "`n", $script:Utf8)
}

function Write-JsonFileAtomic([string]$Path, $Value) {
    $temp = "$Path.sync-tmp"
    [IO.File]::WriteAllText($temp, (Format-Json -Value $Value) + "`n", $script:Utf8)
    if (Test-Path -LiteralPath $Path) {
        Initialize-Native
        [ClaudeAccountSync.Native]::Replace($temp, $Path)
    }
    else {
        [IO.File]::Move($temp, $Path)
    }
}

function Get-KeyUnion($Sources) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $keys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($source in $Sources) {
        foreach ($key in @($source.get_Keys())) {
            if ($seen.Add([string]$key)) { $keys.Add([string]$key) }
        }
    }
    return , $keys
}

function Resolve-Slot([bool]$BaseHas, $Base, $Items) {
    $baseText = $null
    if ($BaseHas) { $baseText = ConvertTo-CompactJson $Base }
    $winner = $null
    foreach ($item in $Items) {
        $text = $null
        if ($item.Has) { $text = ConvertTo-CompactJson $item.Value }
        $same = ($item.Has -eq $BaseHas) -and ($text -ceq $baseText)
        if (-not $same -and ($null -eq $winner -or $item.Time -gt $winner.Time)) { $winner = $item }
    }
    if ($null -eq $winner) { return @{ Has = $BaseHas; Value = $Base } }
    return @{ Has = $winner.Has; Value = $winner.Value }
}

function Merge-Node([bool]$BaseHas, $Base, $Items, [int]$Depth) {
    $resolved = Resolve-Slot $BaseHas $Base $Items
    if (-not $resolved.Has -or $Depth -le 0) { return $resolved }
    if ($BaseHas -and $Base -isnot [System.Collections.IDictionary]) { return $resolved }
    $present = @($Items | Where-Object { $_.Has })
    if ($present.Count -eq 0) { return $resolved }
    foreach ($item in $present) {
        if ($item.Value -isnot [System.Collections.IDictionary]) { return $resolved }
    }
    $sources = @()
    if ($BaseHas) { $sources += , $Base }
    foreach ($item in $present) { $sources += , $item.Value }
    $out = New-Dict
    foreach ($key in (Get-KeyUnion $sources)) {
        $childBaseHas = $BaseHas -and $Base.ContainsKey($key)
        $childBase = $null
        if ($childBaseHas) { $childBase = $Base[$key] }
        $children = @(foreach ($item in $present) {
                $has = $item.Value.ContainsKey($key)
                $value = $null
                if ($has) { $value = $item.Value[$key] }
                @{ Has = $has; Value = $value; Time = $item.Time }
            })
        $node = Merge-Node $childBaseHas $childBase $children ($Depth - 1)
        if ($node.Has) { $out[$key] = $node.Value }
    }
    return @{ Has = $true; Value = $out }
}

function Merge-SharedConfig($Base, $Docs) {
    $out = New-Dict
    foreach ($key in @($script:SharedKeyDepth.Keys)) {
        $depth = $script:SharedKeyDepth[$key]
        $baseHas = ($null -ne $Base) -and $Base.ContainsKey($key)
        $baseValue = $null
        if ($baseHas) { $baseValue = $Base[$key] }
        $items = @(foreach ($doc in $Docs) {
                if ($null -eq $doc.Doc) { continue }
                $has = $doc.Doc.ContainsKey($key)
                if ($depth -gt 0 -and -not $has) { continue }
                $value = $null
                if ($has) { $value = $doc.Doc[$key] }
                @{ Has = $has; Value = $value; Time = $doc.Time }
            })
        $node = Merge-Node $baseHas $baseValue $items $depth
        if ($node.Has) { $out[$key] = $node.Value }
    }
    return , $out
}

function Set-SharedConfig($Doc, $Shared) {
    $out = New-Dict
    if ($null -ne $Doc) {
        foreach ($key in @($Doc.get_Keys())) {
            if (-not $script:SharedKeyDepth.Contains($key)) {
                $out[$key] = $Doc[$key]
            }
            elseif ($Shared.ContainsKey($key)) {
                $out[$key] = $Shared[$key]
            }
        }
    }
    foreach ($key in @($Shared.get_Keys())) {
        if (-not $out.ContainsKey($key)) { $out[$key] = $Shared[$key] }
    }
    return , $out
}

function Initialize-Native {
    if ('ClaudeAccountSync.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ClaudeAccountSync
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfoByHandle
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoByHandle info);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateHardLink(string link, string existing, IntPtr attributes);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool MoveFileEx(string source, string destination, int flags);

        public static string FileId(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                FileInfoByHandle info;
                if (!GetFileInformationByHandle(stream.SafeFileHandle, out info))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return info.VolumeSerialNumber.ToString("x8") + ":" + info.FileIndexHigh.ToString("x8") + info.FileIndexLow.ToString("x8");
            }
        }

        public static void HardLink(string link, string existing)
        {
            if (!CreateHardLink(link, existing, IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static void Replace(string source, string destination)
        {
            if (!MoveFileEx(source, destination, 0x1 | 0x8))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
}

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $script:InstallDir)) { return }
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).old" -Force
        }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message
        [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8)
    }
    catch {
    }
}

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') { throw 'This tool only runs on Windows.' }
}

function Test-Excluded([string]$Name) {
    if ($script:ExcludedNames -contains $Name) { return $true }
    foreach ($pattern in $script:ExcludedPatterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $clean = $Path -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', ''
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($clean)).TrimEnd('\', '/')
}

function Test-SamePath([string]$A, [string]$B) {
    $left = Get-NormalizedPath $A
    $right = Get-NormalizedPath $B
    return ($null -ne $left) -and ($left -ieq $right)
}

function Get-ItemKind([string]$Path, [string]$SharedPath) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'none' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $target = @($item.Target) | Select-Object -First 1
        if ($item.PSIsContainer -and $SharedPath -and (Test-SamePath $target $SharedPath)) { return 'linked' }
        return 'link'
    }
    if ($item.PSIsContainer) { return 'dir' }
    return 'file'
}

function New-Junction([string]$Path, [string]$Target) {
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}

function Remove-Junction([string]$Path) {
    [IO.Directory]::Delete($Path, $false)
}

function Get-ConflictPath([string]$Label, [string]$Name) {
    $dir = Join-Path (Join-Path $script:ConflictDir (Get-Date -Format 'yyyyMMdd-HHmmss')) $Label
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return Join-Path $dir $Name
}

function Invoke-Robocopy([string]$From, [string]$To, [string[]]$Extra) {
    $arguments = @($From, $To, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $Extra
    & robocopy.exe @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying '$From' to '$To' failed (robocopy exit code $LASTEXITCODE)." }
}

function Sync-Directory([string]$Name, [string]$SharedPath, $Entries) {
    if ($null -eq (Get-Item -LiteralPath $SharedPath -Force -ErrorAction SilentlyContinue)) {
        $source = $Entries | Where-Object { $_.Kind -eq 'dir' -or $_.Kind -eq 'link' } | Select-Object -First 1
        if ($null -eq $source) {
            foreach ($entry in $Entries) {
                if ($entry.Kind -eq 'linked') {
                    Remove-Junction $entry.Path
                    Write-Log "Removed '$($entry.Path)' because '$Name' no longer exists in the shared folder"
                }
            }
            return
        }
        [IO.Directory]::Move($source.Path, $SharedPath)
        Write-Log "Moved '$($source.Path)' into the shared folder"
        $source.Kind = 'none'
    }
    foreach ($entry in $Entries) {
        switch ($entry.Kind) {
            'none' {
                New-Junction $entry.Path $SharedPath
                Write-Log "Linked '$($entry.Path)' to the shared folder"
            }
            'dir' {
                Invoke-Robocopy $entry.Path $SharedPath @('/XO', '/XJ')
                $kept = Get-ConflictPath $entry.Profile $Name
                [IO.Directory]::Move($entry.Path, $kept)
                New-Junction $entry.Path $SharedPath
                Write-Log "Merged '$($entry.Path)' into the shared folder and kept the original in '$kept'"
            }
            'link' { Write-Log "Left '$($entry.Path)' alone because it links somewhere else" }
            'file' { Write-Log "Left '$($entry.Path)' alone because it is a file but the shared '$Name' is a folder" }
        }
    }
}

function Set-HardLink([string]$Path, [string]$Target) {
    $temp = "$Path.sync-tmp"
    if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
    [ClaudeAccountSync.Native]::HardLink($temp, $Target)
    [ClaudeAccountSync.Native]::Replace($temp, $Path)
}

function Sync-File([string]$Name, [string]$SharedPath, $Entries) {
    Initialize-Native
    $shared = $null
    if (Test-Path -LiteralPath $SharedPath -PathType Leaf) {
        $shared = @{
            Path   = $SharedPath
            Id     = [ClaudeAccountSync.Native]::FileId($SharedPath)
            Time   = (Get-Item -LiteralPath $SharedPath -Force).LastWriteTimeUtc
            Shared = $true
        }
    }
    foreach ($entry in $Entries) {
        if ($entry.Kind -eq 'file') {
            $entry.Id = [ClaudeAccountSync.Native]::FileId($entry.Path)
            $entry.Time = (Get-Item -LiteralPath $entry.Path -Force).LastWriteTimeUtc
        }
    }
    $sharedId = $null
    if ($null -ne $shared) { $sharedId = $shared.Id }
    $outOfSync = @($Entries | Where-Object { $_.Kind -eq 'file' -and $_.Id -ne $sharedId })
    $missing = @($Entries | Where-Object { $_.Kind -eq 'none' })
    if ($null -ne $shared -and $outOfSync.Count -eq 0 -and $missing.Count -eq 0) { return }

    $winner = $shared
    foreach ($entry in $outOfSync) {
        if ($null -eq $winner -or $entry.Time -gt $winner.Time) { $winner = $entry }
    }
    if ($null -eq $winner) { return }
    if (-not $winner.Shared) {
        [ClaudeAccountSync.Native]::Replace($winner.Path, $SharedPath)
        $winner.Kind = 'none'
        Write-Log "Updated shared '$Name' from the $($winner.Profile) account"
    }
    $sharedHash = (Get-FileHash -LiteralPath $SharedPath -Algorithm SHA256).Hash
    foreach ($entry in $Entries) {
        if ($entry.Kind -eq 'file' -and $entry.Id -ne $winner.Id) {
            if ((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -ne $sharedHash) {
                $kept = Get-ConflictPath $entry.Profile $Name
                Copy-Item -LiteralPath $entry.Path -Destination $kept -Force
                Write-Log "Replaced an older '$Name' in the $($entry.Profile) account and kept it in '$kept'"
            }
            Set-HardLink $entry.Path $SharedPath
        }
        elseif ($entry.Kind -eq 'none') {
            [ClaudeAccountSync.Native]::HardLink($entry.Path, $SharedPath)
            Write-Log "Linked '$($entry.Path)' to the shared file"
        }
        elseif ($entry.Kind -eq 'link') {
            Write-Log "Left '$($entry.Path)' alone because it links somewhere else"
        }
    }
}

function Sync-Item($Config, [string]$Name) {
    $sharedPath = Join-Path $Config.shared $Name
    $entries = @(foreach ($account in $Config.profiles) {
            $path = Join-Path $account.path $Name
            @{ Profile = $account.name; Path = $path; Kind = (Get-ItemKind $path $sharedPath) }
        })
    $sharedItem = Get-Item -LiteralPath $sharedPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $sharedItem) {
        $isDir = $sharedItem.PSIsContainer
    }
    else {
        $first = $entries | Where-Object { $_.Kind -eq 'dir' -or $_.Kind -eq 'file' -or $_.Kind -eq 'link' } | Select-Object -First 1
        if ($null -eq $first) {
            $isDir = $true
        }
        else {
            $isDir = (Get-Item -LiteralPath $first.Path -Force).PSIsContainer
        }
    }
    if ($isDir) { Sync-Directory $Name $sharedPath $entries } else { Sync-File $Name $sharedPath $entries }
}

function Sync-Links($Config) {
    if (-not (Test-Path -LiteralPath $Config.shared)) { New-Item -ItemType Directory -Path $Config.shared | Out-Null }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $names = New-Object 'System.Collections.Generic.List[string]'
    $dirs = @($Config.shared) + @($Config.profiles | ForEach-Object { $_.path })
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force)) {
            if (-not (Test-Excluded $child.Name) -and $seen.Add($child.Name)) { $names.Add($child.Name) }
        }
    }
    foreach ($name in $names) {
        try {
            Sync-Item $Config $name
        }
        catch {
            Write-Log "Could not sync '$name': $($_.Exception.Message)"
        }
    }
}

function Get-AccountEmail($Doc) {
    if ($null -eq $Doc -or -not $Doc.ContainsKey('oauthAccount')) { return $null }
    $account = $Doc['oauthAccount']
    if ($account -isnot [System.Collections.IDictionary] -or -not $account.ContainsKey('emailAddress')) { return $null }
    return [string]$account['emailAddress']
}

function Sync-Configs($Config) {
    $docs = @(foreach ($account in $Config.profiles) {
            $path = Join-Path $account.path '.claude.json'
            $doc = $null
            $time = [datetime]::MinValue
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $doc = Read-JsonFile $path
                $time = (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc
            }
            @{ Account = $account; Path = $path; Doc = $doc; Time = $time }
        })
    $base = Read-JsonFile $script:BasePath
    $shared = Merge-SharedConfig $base $docs
    foreach ($entry in $docs) {
        $updated = Set-SharedConfig $entry.Doc $shared
        if ($null -eq $entry.Doc -or (ConvertTo-CompactJson $updated) -cne (ConvertTo-CompactJson $entry.Doc)) {
            Write-JsonFileAtomic $entry.Path $updated
            Write-Log "Updated shared settings in '$($entry.Path)'"
        }
        $label = $entry.Account.name
        $email = Get-AccountEmail $entry.Doc
        if ($email) { $label = "$label | $email" }
        $labelPath = Join-Path $entry.Account.path $script:LabelFile
        $current = $null
        if (Test-Path -LiteralPath $labelPath) { $current = [IO.File]::ReadAllText($labelPath) }
        if ($current -cne $label) { [IO.File]::WriteAllText($labelPath, $label, $script:Utf8) }
    }
    Write-JsonFile $script:BasePath $shared
}

function Remove-OldConflicts {
    if (-not (Test-Path -LiteralPath $script:ConflictDir)) { return }
    $cutoff = (Get-Date).AddDays(-$script:ConflictRetentionDays)
    foreach ($dir in @(Get-ChildItem -LiteralPath $script:ConflictDir -Directory)) {
        if ($dir.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force }
    }
}

function Enter-SyncLock {
    $path = Join-Path $script:InstallDir 'sync.lock'
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            return [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw 'Another sync is still running. Try again in a minute.'
}

function Invoke-Sync($Config) {
    $lock = Enter-SyncLock
    try {
        Sync-Links $Config
        Sync-Configs $Config
        Remove-OldConflicts
    }
    finally {
        $lock.Dispose()
    }
}

function Read-Config {
    $config = Read-JsonFile $script:ConfigPath
    if ($null -eq $config) { throw 'Claude Account Sync is not set up yet. Run setup.cmd first.' }
    return , $config
}

function New-AccountEntry([string]$Name, [string]$Path) {
    $entry = New-Dict
    $entry['name'] = $Name
    $entry['path'] = $Path
    return , $entry
}

function Find-Account($Config, [string]$Name) {
    foreach ($account in $Config.profiles) {
        if ($account.name -ieq $Name) { return , $account }
    }
    return $null
}

function Get-ActiveAccount($Config) {
    $current = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
    if ([string]::IsNullOrWhiteSpace($current)) { return , $Config.profiles[0] }
    foreach ($account in $Config.profiles) {
        if (Test-SamePath $current $account.path) { return , $account }
    }
    return $null
}

function Set-ActiveAccount($Account) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $Account.path, 'User')
    $env:CLAUDE_CONFIG_DIR = $Account.path
}

function Test-LoggedIn($Account) {
    return Test-Path -LiteralPath (Join-Path $Account.path '.credentials.json')
}

function Get-ClaudeProcesses {
    return @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
}

function Assert-ClaudeClosed([switch]$Force) {
    if ($Force) { return }
    if ((Get-ClaudeProcesses).Count -gt 0) {
        throw 'Claude is still running. Quit Claude Desktop (including its tray icon), close VS Code, Zed and any terminal running Claude Code, then try again.'
    }
}

function Backup-Existing([string[]]$Paths) {
    $target = Join-Path $script:BackupDir (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $leaf = Split-Path -Leaf $path
        if ((Get-Item -LiteralPath $path -Force).PSIsContainer) {
            Invoke-Robocopy $path (Join-Path $target $leaf) @('/XJ')
        }
        else {
            Copy-Item -LiteralPath $path -Destination (Join-Path $target $leaf) -Force
        }
    }
    return $target
}

function Install-Files {
    if (Test-SamePath $script:SourceDir $script:InstallDir) { return }
    New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
    Copy-Item -Path (Join-Path $script:SourceDir '*.ps1') -Destination $script:InstallDir -Force
    Copy-Item -Path (Join-Path $script:SourceDir 'bin\*.cmd') -Destination $script:BinDir -Force
}

function Remove-DesktopFiles {
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($file in $script:DesktopFiles) {
        $path = Join-Path $desktop $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Get-UserPathEntries {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        $value = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally {
        $key.Close()
    }
    return @($value -split ';' | Where-Object { $_ -ne '' })
}

function Set-UserPathEntries([string[]]$Entries) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $key.SetValue('Path', ($Entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $key.Close()
    }
}

function Test-IsBinEntry([string]$Entry) {
    return ($Entry -ieq $script:BinPathEntry) -or (Test-SamePath $Entry $script:BinDir)
}

function Add-BinToPath {
    $entries = Get-UserPathEntries
    foreach ($entry in $entries) { if (Test-IsBinEntry $entry) { return } }
    Set-UserPathEntries (@($entries) + $script:BinPathEntry)
}

function Remove-BinFromPath {
    $entries = Get-UserPathEntries
    $kept = @($entries | Where-Object { -not (Test-IsBinEntry $_) })
    if ($kept.Count -ne $entries.Count) { Set-UserPathEntries $kept }
}

function Register-SyncTask {
    try {
        $script = Join-Path $script:InstallDir 'claude-account-sync.ps1'
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" sync -Quiet"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        return $true
    }
    catch {
        Write-Log "Could not register the scheduled sync: $($_.Exception.Message)"
        return $false
    }
}

function Unregister-SyncTask {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
}

function Test-SyncTask {
    return $null -ne (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}

function Get-StatusLineCommand {
    $script = (Join-Path $script:InstallDir 'statusline.ps1').Replace('\', '/')
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
}

function Add-StatusLine($Config) {
    $path = Join-Path $Config.shared 'settings.json'
    $settings = Read-JsonFile $path
    if ($null -eq $settings) { $settings = New-Dict }
    if ($settings.ContainsKey('statusLine')) { return $false }
    $line = New-Dict
    $line['type'] = 'command'
    $line['command'] = Get-StatusLineCommand
    $settings['statusLine'] = $line
    Write-JsonFile $path $settings
    return $true
}

function Remove-StatusLine($Config) {
    $path = Join-Path $Config.shared 'settings.json'
    $settings = Read-JsonFile $path
    if ($null -eq $settings -or -not $settings.ContainsKey('statusLine')) { return }
    $line = $settings['statusLine']
    if ($line -is [System.Collections.IDictionary] -and $line.ContainsKey('command') -and ([string]$line['command']).Contains('.claude-account-sync')) {
        [void]$settings.Remove('statusLine')
        Write-JsonFile $path $settings
    }
}

function Restore-Account($Account, $Config, [bool]$Move) {
    if (-not (Test-Path -LiteralPath $Account.path)) { return }
    Initialize-Native
    foreach ($child in @(Get-ChildItem -LiteralPath $Account.path -Force)) {
        if (Test-Excluded $child.Name) { continue }
        $sharedPath = Join-Path $Config.shared $child.Name
        $kind = Get-ItemKind $child.FullName $sharedPath
        if ($kind -eq 'linked') {
            Remove-Junction $child.FullName
            if (Test-Path -LiteralPath $sharedPath) {
                if ($Move) { [IO.Directory]::Move($sharedPath, $child.FullName) } else { Invoke-Robocopy $sharedPath $child.FullName @() }
            }
        }
        elseif ($kind -eq 'file' -and (Test-Path -LiteralPath $sharedPath -PathType Leaf) -and ([ClaudeAccountSync.Native]::FileId($child.FullName) -eq [ClaudeAccountSync.Native]::FileId($sharedPath))) {
            [IO.File]::Delete($child.FullName)
            if ($Move) { [IO.File]::Move($sharedPath, $child.FullName) } else { Copy-Item -LiteralPath $sharedPath -Destination $child.FullName -Force }
        }
    }
    if ($Move -and (Test-Path -LiteralPath $Config.shared)) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Config.shared -Force)) {
            $destination = Join-Path $Account.path $child.Name
            if (-not (Test-Path -LiteralPath $destination)) {
                if ($child.PSIsContainer) { [IO.Directory]::Move($child.FullName, $destination) } else { [IO.File]::Move($child.FullName, $destination) }
            }
        }
    }
    $label = Join-Path $Account.path $script:LabelFile
    if (Test-Path -LiteralPath $label) { Remove-Item -LiteralPath $label -Force }
}

function Invoke-Setup([switch]$Force) {
    Assert-Windows
    Assert-ClaudeClosed -Force:$Force
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    $config = Read-JsonFile $script:ConfigPath
    $firstRun = $null -eq $config
    if ($firstRun) {
        $personal = Join-Path $script:HomeDir '.claude'
        $org = Join-Path $script:HomeDir '.claude-org'
        $legacyJson = Join-Path $script:HomeDir '.claude.json'
        Write-Host 'Backing up your current Claude data...'
        $backup = Backup-Existing @($personal, $org, $legacyJson)
        Write-Host "Backup saved to $backup"
        foreach ($dir in @($personal, $org)) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        }
        $personalJson = Join-Path $personal '.claude.json'
        if (-not (Test-Path -LiteralPath $personalJson) -and (Test-Path -LiteralPath $legacyJson)) {
            Copy-Item -LiteralPath $legacyJson -Destination $personalJson
        }
        $config = New-Dict
        $config['shared'] = Join-Path $script:HomeDir '.claude-shared'
        $accounts = New-Object 'System.Collections.Generic.List[object]'
        $accounts.Add((New-AccountEntry 'personal' $personal))
        $accounts.Add((New-AccountEntry 'org' $org))
        $config['profiles'] = $accounts.ToArray()
        Write-JsonFile $script:ConfigPath $config
    }
    Install-Files
    Write-Host 'Moving shared data into place...'
    Invoke-Sync $config
    $statusLine = Add-StatusLine $config
    Invoke-Sync $config
    Add-BinToPath
    Remove-DesktopFiles
    $task = Register-SyncTask
    $active = Get-ActiveAccount $config
    if ($null -eq $active) { $active = $config.profiles[0] }
    Set-ActiveAccount $active
    Write-Host ''
    Write-Host 'Setup complete.' -ForegroundColor Green
    Write-Host "Active account: $($active.name)"
    if (-not $task) { Write-Host 'Automatic background sync could not be turned on. Data still syncs every time you switch accounts.' -ForegroundColor Yellow }
    if (-not $statusLine) { Write-Host 'You already have a status line, so it was left as is. Type /status in Claude Code to see the current account.' }
    $org = Find-Account $config 'org'
    if ($null -ne $org -and -not (Test-LoggedIn $org)) {
        Write-Host ''
        Write-Host 'One more step: open a new terminal, run claude-org, then type /login and sign in with your org account.'
    }
    Write-Host 'Switch accounts with the two Switch files next to setup.cmd.'
}

function Invoke-Switch([string]$Name) {
    Assert-Windows
    $config = Read-Config
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Say which account to switch to, for example: claude-account switch org' }
    $target = Find-Account $config $Name
    if ($null -eq $target) {
        $names = ($config.profiles | ForEach-Object { $_.name }) -join ', '
        throw "There is no account named '$Name'. Accounts: $names."
    }
    try {
        Invoke-Sync $config
    }
    catch {
        Write-Host "Sync didn't finish: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Set-ActiveAccount $target
    $email = Get-AccountEmail (Read-JsonFile (Join-Path $target.path '.claude.json'))
    $line = "Now using the $($target.name) account"
    if ($email) { $line = "$line ($email)" }
    Write-Host $line -ForegroundColor Green
    if (-not (Test-LoggedIn $target)) {
        Write-Host "This account isn't logged in yet. Open a new terminal, run claude-$($target.name), then type /login." -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Restart VS Code, Zed and any open terminals so they pick up the change.'
    Write-Host 'Claude Desktop keeps its own sign-in. Sign out and back in there to use the same account.'
}

function Invoke-SyncCommand([switch]$Quiet) {
    Assert-Windows
    $config = Read-JsonFile $script:ConfigPath
    if ($null -eq $config) {
        if ($Quiet) { return }
        throw 'Claude Account Sync is not set up yet. Run setup.cmd first.'
    }
    Invoke-Sync $config
    if (-not $Quiet) { Write-Host 'Sync complete.' -ForegroundColor Green }
}

function Show-Status {
    Assert-Windows
    $config = Read-Config
    $active = Get-ActiveAccount $config
    if ($null -eq $active) {
        Write-Host "Active account: none of yours (CLAUDE_CONFIG_DIR points to $([Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')))" -ForegroundColor Yellow
    }
    else {
        Write-Host "Active account: $($active.name)" -ForegroundColor Green
    }
    Write-Host ''
    foreach ($account in $config.profiles) {
        $email = Get-AccountEmail (Read-JsonFile (Join-Path $account.path '.claude.json'))
        $state = if (-not (Test-LoggedIn $account)) { 'not logged in' } elseif ($email) { $email } else { 'logged in' }
        Write-Host ('  {0,-10} {1,-12} {2}' -f $account.name, $state, $account.path)
    }
    Write-Host ''
    Write-Host "Shared data:     $($config.shared)"
    $syncState = if (Test-SyncTask) { 'on, every 10 minutes' } else { 'off' }
    Write-Host "Automatic sync:  $syncState"
    Write-Host "Log:             $($script:LogPath)"
}

function Invoke-Uninstall([switch]$Force) {
    Assert-Windows
    $config = Read-Config
    Assert-ClaudeClosed -Force:$Force
    Write-Host 'Syncing one last time...'
    Invoke-Sync $config
    Unregister-SyncTask
    Remove-BinFromPath
    Remove-DesktopFiles
    Remove-StatusLine $config
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $null, 'User')
    $primary = $config.profiles[0]
    foreach ($account in @($config.profiles | Select-Object -Skip 1)) {
        Write-Host "Giving the $($account.name) account its own copy of the data..."
        Restore-Account $account $config $false
    }
    Write-Host "Moving the shared data back into $($primary.path)..."
    Restore-Account $primary $config $true
    $primaryJson = Join-Path $primary.path '.claude.json'
    $legacyJson = Join-Path $script:HomeDir '.claude.json'
    if ((Test-SamePath $primary.path (Join-Path $script:HomeDir '.claude')) -and (Test-Path -LiteralPath $primaryJson)) {
        $backup = Backup-Existing @($legacyJson)
        Move-Item -LiteralPath $primaryJson -Destination $legacyJson -Force
        Write-Log "Restored '$legacyJson'; the previous copy is in '$backup'"
    }
    if ((Test-Path -LiteralPath $config.shared) -and @(Get-ChildItem -LiteralPath $config.shared -Force).Count -eq 0) {
        [IO.Directory]::Delete($config.shared, $false)
    }
    foreach ($path in @((Join-Path $script:InstallDir '*.ps1'), $script:BinDir, (Join-Path $script:InstallDir 'desktop'), $script:ConfigPath, $script:BasePath, (Join-Path $script:InstallDir 'sync.lock'))) {
        if (Test-Path -Path $path) { Remove-Item -Path $path -Recurse -Force }
    }
    Write-Host ''
    Write-Host 'Uninstalled. Everything is back in a normal .claude folder.' -ForegroundColor Green
    foreach ($account in @($config.profiles | Select-Object -Skip 1)) {
        Write-Host "The $($account.name) account is still in $($account.path) with its own copy of your data."
    }
    Write-Host "Backups are kept in $($script:BackupDir)."
}
