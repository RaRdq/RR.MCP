param(
    [Parameter(Mandatory=$false)]
    [string]$SolutionFile = "*.sln"
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output '{"type":"result","payload":{"Models":[],"Entities":[],"Types":[],"PlainText":"Error: PowerShell 7+ required."}}'
    exit 0
}

$logFile = Join-Path $PSScriptRoot "mcp_data_debug.log"

$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Clean-Doc { param([string]$t) if ([string]::IsNullOrWhiteSpace($t)) { return "" } $t -replace '<.*?>', '' -replace '\s+', ' ' }

function Get-SolutionProjects {
    param([string]$SolutionPath)
    if (-not (Test-Path $SolutionPath)) { return @() }
    $solutionDir = Split-Path -Parent $SolutionPath
    $solutionContent = Get-Content -Path $SolutionPath -Raw -ErrorAction SilentlyContinue
    $projectMatches = [regex]::Matches($solutionContent, 'Project\([^)]+\) = "[^"]+", "([^"]+)"')
    $projectPaths = @()
    foreach ($match in $projectMatches) {
        $relativePath = $match.Groups[1].Value
        if ($relativePath -like "*.csproj") {
            $fullPath = Join-Path $solutionDir $relativePath
            $fullPath = [System.IO.Path]::GetFullPath($fullPath)
            if (Test-Path $fullPath) {
                $projectDir = Split-Path -Parent $fullPath
                $projectPaths += $projectDir
            }
        }
    }
    return $projectPaths
}

function Get-GitIgnorePatterns {
    param([string]$WorkspacePath)
    $gitIgnorePath = Join-Path $WorkspacePath ".gitignore"
    if (-not (Test-Path $gitIgnorePath)) { return @("\\bin\\", "\\obj\\", "\\node_modules\\", "\\packages\\", "\\.vs\\", "\\.git\\") }
    $patterns = @()
    $gitIgnoreContent = Get-Content -Path $gitIgnorePath -ErrorAction SilentlyContinue
    foreach ($line in $gitIgnoreContent) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $pattern = $line.Trim()
        if ($pattern.StartsWith('!')) { continue }
        $pattern = $pattern -replace '\.', '\.'
        $pattern = $pattern -replace '\*', '.*'
        $pattern = $pattern -replace '/', '\\'
        if (-not $pattern.StartsWith('\\')) { $pattern = "\\$pattern" }
        $patterns += $pattern
    }
    $patterns += "\\bin\\"; $patterns += "\\obj\\"
    return $patterns
}

function Get-ProjectFingerprint {
    param([string]$ProjectPath, [array]$IgnorePatterns)
    $CsFiles = Get-ChildItem -Path $ProjectPath -Recurse -Filter "*.cs" -File
    foreach ($pattern in $IgnorePatterns) { $CsFiles = $CsFiles | Where-Object { $_.FullName -notmatch $pattern } }
    $FileInfos = @(); foreach ($file in $CsFiles) { $FileInfos += "$($file.FullName)|$($file.LastWriteTimeUtc)" }
    $FileInfosString = ($FileInfos | Sort-Object) -join "`n"
    $FileStateBytes = [System.Text.Encoding]::UTF8.GetBytes($FileInfosString)
    $MemStream = [System.IO.MemoryStream]::new($FileStateBytes)
    $Hash = (Get-FileHash -Algorithm SHA256 -InputStream $MemStream).Hash
    return $Hash
}

function Extract-ProjectData {
    param([string]$ProjectPath, [array]$IgnorePatterns, [string]$ProjectCacheDir)
    $ProjectName = (Get-Item $ProjectPath).Name
    $ProjectCacheFile = Join-Path $ProjectCacheDir "$ProjectName.json"
    $ProjectHash = Get-ProjectFingerprint -ProjectPath $ProjectPath -IgnorePatterns $IgnorePatterns
    if (Test-Path $ProjectCacheFile) {
        $CachedContent = Get-Content -Path $ProjectCacheFile -Raw -ErrorAction SilentlyContinue
        $CachedObject = $CachedContent | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($CachedObject -and $CachedObject.Hash -eq $ProjectHash) { return $CachedObject.Data }
    }
    $CsFiles = Get-ChildItem -Path $ProjectPath -Recurse -Filter "*.cs" -File
    foreach ($pattern in $IgnorePatterns) { $CsFiles = $CsFiles | Where-Object { $_.FullName -notmatch $pattern } }
    $CsFilePaths = $CsFiles | Select-Object -ExpandProperty FullName
    $Models = @(); $Entities = @(); $Types = @()
    foreach ($FilePath in $CsFilePaths) {
        try {
            $Content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
            # Models 
            $ModelMatches = [regex]::Matches($Content, '(?sm)public\s+(?:partial\s+)?class\s+(\w+Model)\s*(?:\:\s*([\w<>]+))?\s*\{(?<body>.*?)\}')
            foreach ($match in $ModelMatches) {
                $name = $match.Groups[1].Value; $base = $match.Groups[2].Value; $body = $match.Groups['body'].Value
                $props = @{}
                $propMatches = [regex]::Matches($body, '(?m)\s*(?:\[.*?\]\s*)*public\s+([\w\[\]<>\?]+)\s+(\w+)\s*{')
                foreach ($pm in $propMatches) { $props[$pm.Groups[2].Value] = $pm.Groups[1].Value }
                $Models += @{ n = $name; base = $base; p = $props; prj = $ProjectName } # $FilePath not used to reduce output tokensize
            }
            # Entities 
            $EntityMatches = [regex]::Matches($Content, '(?sm)public\s+(?:partial\s+)?class\s+(\w+Entity)\s*\:\s*([\w<>]+)\s*\{(?<body>.*?)\}')
            foreach ($match in $EntityMatches) {
                $name = $match.Groups[1].Value; $base = $match.Groups[2].Value; $body = $match.Groups['body'].Value
                $props = @{}
                $propMatches = [regex]::Matches($body, '(?m)\s*(?:\[.*?\]\s*)*public\s+([\w\[\]<>\?]+)\s+(\w+)\s*{')
                foreach ($pm in $propMatches) { $props[$pm.Groups[2].Value] = $pm.Groups[1].Value }
                $Entities += @{ n = $name; base = $base; p = $props; prj = $ProjectName }
            }
            # Types (enums)
            $TypeMatches = [regex]::Matches($Content, '(?sm)public\s+enum\s+(\w+Type)\s*\{(?<body>.*?)\}')
            foreach ($match in $TypeMatches) {
                $name = $match.Groups[1].Value; $body = $match.Groups['body'].Value
                $members = @{}
                $memberMatches = [regex]::Matches($body, '(?m)\s*(\w+)\s*=\s*([0-9]+)')
                foreach ($mm in $memberMatches) { $members[$mm.Groups[1].Value] = [int]$mm.Groups[2].Value }
                $Types += @{ n = $name; m = $members; prj = $ProjectName }
            }
        } catch { }
    }
    $Data = @{ Models = $Models; Entities = $Entities; Types = $Types }
    $CacheObject = @{ Hash = $ProjectHash; Data = $Data }
    $CacheContent = ConvertTo-Json -InputObject $CacheObject -Depth 10 -Compress
    $CacheContent | Out-File -FilePath $ProjectCacheFile -Encoding UTF8 -Force
    return $Data
}

try {
    $scriptRoot = $PSScriptRoot
    $WorkspaceRoot = $null
    if (Test-Path (Join-Path $scriptRoot ".." $SolutionFile)) { $WorkspaceRoot = (Get-Item $scriptRoot).Parent.FullName }
    elseif (Test-Path (Join-Path $scriptRoot $SolutionFile)) { $WorkspaceRoot = $scriptRoot }
    elseif (Test-Path (Join-Path (Get-Location).Path $SolutionFile)) { $WorkspaceRoot = (Get-Location).Path }
    else {
        $currentDir = $scriptRoot
        while ($currentDir -ne $null -and -not (Test-Path (Join-Path $currentDir $SolutionFile))) {
            $parent = Split-Path -Parent $currentDir
            if ($parent -eq $currentDir) { $currentDir = $null } else { $currentDir = $parent }
        }
        if ($currentDir -ne $null) { $WorkspaceRoot = $currentDir }
    }
    if (-not $WorkspaceRoot) {
        Write-Output '{"type":"result","payload":{"Models":[],"Entities":[],"Types":[],"PlainText":"Could not find workspace root with solution file."}}'
        exit 0
    }
    $SolutionPath = Join-Path $WorkspaceRoot $SolutionFile
    $ProjectPaths = Get-SolutionProjects -SolutionPath $SolutionPath
    $CacheDir = Join-Path $WorkspaceRoot ".cache"
    $ProjectCacheDir = Join-Path $CacheDir "projects_data"
    if (!(Test-Path -Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    if (!(Test-Path -Path $ProjectCacheDir)) { New-Item -ItemType Directory -Path $ProjectCacheDir -Force | Out-Null }
    $IgnorePatterns = Get-GitIgnorePatterns -WorkspacePath $WorkspaceRoot
    $AllModels = @(); $AllEntities = @(); $AllTypes = @()
    foreach ($ProjectPath in $ProjectPaths) {
        if (-not (Test-Path $ProjectPath)) { continue }
        try {
            $Data = Extract-ProjectData -ProjectPath $ProjectPath -IgnorePatterns $IgnorePatterns -ProjectCacheDir $ProjectCacheDir
            $AllModels += $Data.Models; $AllEntities += $Data.Entities; $AllTypes += $Data.Types
        } catch { }
    }
    $Result = @{ type = "result"; payload = @{ Models = $AllModels; Entities = $AllEntities; Types = $AllTypes; PlainText = "" } }
    $ResultJson = ConvertTo-Json -InputObject $Result -Depth 10 -Compress -EscapeHandling EscapeNonAscii
    $ResultJson | Out-File -FilePath (Join-Path $CacheDir "data_output.json") -Encoding UTF8 -Force
    Write-Output $ResultJson
} catch {
    Write-Output '{"type":"result","payload":{"Models":[],"Entities":[],"Types":[],"PlainText":"Error: Exception in script."}}'
    exit 0
} 