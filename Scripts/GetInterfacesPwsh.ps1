param(
    [Parameter(Mandatory=$false)]
    [string]$SolutionFile = "*.sln"
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    "[FATAL] PowerShell version $($PSVersionTable.PSVersion) is not supported. Please use PowerShell 7+" | Out-File -FilePath "$PSScriptRoot\\mcp_debug.log" -Append
    Write-Output '{"type":"result","payload":{"Interfaces":[]}}'
    exit 0
}

$logFile = Join-Path $PSScriptRoot "mcp_debug.log"
"[LOG] Script started at $(Get-Date)" | Out-File -FilePath $logFile -Append
"[LOG] SolutionFile param: $SolutionFile" | Out-File -FilePath $logFile -Append

# Suppress console error output completely
$null = [Console]::Error.Write("")

# Force all PowerShell output streams to null to prevent any non-JSON output
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ErrorActionPreference = "SilentlyContinue"

# Set output encoding to UTF-8 without BOM
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

function Extract-ProjectInterfaces {
    param([string]$ProjectPath, [array]$IgnorePatterns, [string]$ProjectCacheDir)
    $ProjectName = (Get-Item $ProjectPath).Name
    $ProjectCacheFile = Join-Path $ProjectCacheDir "$ProjectName.json"
    $ProjectHash = Get-ProjectFingerprint -ProjectPath $ProjectPath -IgnorePatterns $IgnorePatterns
    if (Test-Path $ProjectCacheFile) {
        $CachedContent = Get-Content -Path $ProjectCacheFile -Raw -ErrorAction SilentlyContinue
        $CachedObject = $CachedContent | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($CachedObject -and $CachedObject.Hash -eq $ProjectHash) { return $CachedObject.Interfaces }
    }
    $CsFiles = Get-ChildItem -Path $ProjectPath -Recurse -Filter "*.cs" -File
    foreach ($pattern in $IgnorePatterns) { $CsFiles = $CsFiles | Where-Object { $_.FullName -notmatch $pattern } }
    $CsFilePaths = $CsFiles | Select-Object -ExpandProperty FullName
    $Interfaces = @()
    foreach ($FilePath in $CsFilePaths) {
        try {
            $Content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
            # Match interface with XML/OpenAPI comments
            $InterfaceMatches = [regex]::Matches($Content, '(?sm)(?:(?:\/\/\/(?<idoc>.*?)\r?\n\s*)|(?:\/\*\*(?<idoc>.*?)\*\/\s*))?(?:\[.*?\]\s*)*public\s+interface\s+(?<iname>\w+)(?:\s*\:\s*(?<ibase>.*?))?\s*\{(?<ibody>.*?)\}')
            foreach ($IMatch in $InterfaceMatches) {
                $InterfaceName = $IMatch.Groups['iname'].Value
                $InterfaceBase = $IMatch.Groups['ibase'].Value.Trim()
                $InterfaceDoc = Clean-Doc $IMatch.Groups['idoc'].Value
                $InterfaceBody = $IMatch.Groups['ibody'].Value
                $Methods = @()
                # Match methods with XML/OpenAPI comments
                $MethodMatches = [regex]::Matches($InterfaceBody, '(?sm)(?:(?:\/\/\/(?<mdoc>.*?)\r?\n\s*)|(?:\/\*\*(?<mdoc>.*?)\*\/\s*))?(?:\[.*?\]\s*)*(?<msig>[\w\<\>\[\]\?\,\s\.]+\s+[\w]+\s*\(.*?\))\s*;')
                foreach ($MMatch in $MethodMatches) {
                    $MethodSignature = $MMatch.Groups['msig'].Value.Trim() -replace '\s+', ' '
                    $MethodDoc = Clean-Doc $MMatch.Groups['mdoc'].Value
                    if ($MethodDoc) {
                        $Methods += @{ s = $MethodSignature; d = $MethodDoc }
                    } else {
                        $Methods += $MethodSignature
                    }
                }
                if ($Methods.Count -gt 0) {
                    $InterfaceData = @{ 
                        n = $InterfaceName
                        m = $Methods
                        prj = $ProjectName
                    }
                    if ($InterfaceBase) { $InterfaceData.b = $InterfaceBase }
                    if ($InterfaceDoc) { $InterfaceData.d = $InterfaceDoc }
                    $Interfaces += $InterfaceData
                }
            }
        } catch { }
    }
    $CacheObject = @{ Hash = $ProjectHash; Interfaces = $Interfaces }
    $CacheContent = ConvertTo-Json -InputObject $CacheObject -Depth 10 -Compress
    $CacheContent | Out-File -FilePath $ProjectCacheFile -Encoding UTF8 -Force
    return $Interfaces
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
        "[ERROR] Could not find workspace root with solution file: $SolutionFile" | Out-File -FilePath $logFile -Append
        Write-Output '{"type":"result","payload":{"Interfaces":[]}}'
        exit 0
    }
    $SolutionPath = Join-Path $WorkspaceRoot $SolutionFile
    $ProjectPaths = Get-SolutionProjects -SolutionPath $SolutionPath
    $CacheDir = Join-Path $WorkspaceRoot ".cache"
    $ProjectCacheDir = Join-Path $CacheDir "projects_interfaces"
    if (!(Test-Path -Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    if (!(Test-Path -Path $ProjectCacheDir)) { New-Item -ItemType Directory -Path $ProjectCacheDir -Force | Out-Null }
    $IgnorePatterns = Get-GitIgnorePatterns -WorkspacePath $WorkspaceRoot
    $AllInterfaces = @()
    foreach ($ProjectPath in $ProjectPaths) {
        if (-not (Test-Path $ProjectPath)) { continue }
        try {
            $ProjectInterfaces = Extract-ProjectInterfaces -ProjectPath $ProjectPath -IgnorePatterns $IgnorePatterns -ProjectCacheDir $ProjectCacheDir
            $AllInterfaces += $ProjectInterfaces
        } catch {
            "Error processing project $ProjectPath : $_" | Out-File -FilePath $logFile -Append
            # Continue with next project
        }
    }
    $Result = @{ type = "result"; payload = @{ Interfaces = $AllInterfaces } }
    $ResultJson = ConvertTo-Json -InputObject $Result -Depth 10 -Compress -EscapeHandling EscapeNonAscii
    $ResultJson | Out-File -FilePath (Join-Path $CacheDir "interfaces_output.json") -Encoding UTF8 -Force
    Write-Output $ResultJson
} catch {
    "[FATAL] Exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" | Out-File -FilePath $logFile -Append
    Write-Output '{"type":"result","payload":{"Interfaces":[]}}'
    exit 0
}