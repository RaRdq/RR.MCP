param(
    [Parameter(Mandatory=$false)]
    [string]$SolutionFile = "*.sln",
    [Parameter(Mandatory=$false)]
    [string]$ResourcesPath = "Resources"
)

# Clean up whitespace and comments
function Clean-Doc { param([string]$t) if ([string]::IsNullOrWhiteSpace($t)) { return "" } $t -replace '<.*?>', '' -replace '\s+', ' ' }

# Discover projects in solution
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

# Get ignore patterns from .gitignore
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

# --- NEW: Scan .resx files for keys/values ---
function Get-ResxKeysAndValues {
    param([string[]]$ProjectPaths)
    $resxFiles = @()
    foreach ($projectPath in $ProjectPaths) {
        if (Test-Path $projectPath) {
            $resxFiles += Get-ChildItem -Path $projectPath -Recurse -Filter *.resx -File -ErrorAction SilentlyContinue
        }
    }
    $resxData = @{}
    foreach ($file in $resxFiles) {
        $resourceName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        $xml = [xml](Get-Content -Path $file.FullName -Raw)
        $dict = @{}
        foreach ($data in $xml.root.data) {
            $key = $data.name.Trim()
            $value = $null
            if ($data.value) { $value = [string]$data.value }
            if ($null -eq $value) { $value = "" }
            $dict[$key] = $value
        }
        $resxData[$resourceName] = $dict
    }
    return $resxData
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
        Write-Output '{"type":"result","payload":{"DiscoveredKeys":{}}}'
        exit 0
    }
    $SolutionPath = Join-Path $WorkspaceRoot $SolutionFile
    $ProjectPaths = Get-SolutionProjects -SolutionPath $SolutionPath
    if (-not $ProjectPaths -or $ProjectPaths.Count -eq 0) {
        $ProjectPaths = Get-ChildItem -Path $WorkspaceRoot -Recurse -Include *.csproj -File | ForEach-Object { $_.Directory.FullName } | Select-Object -Unique
    }
    $IgnorePatterns = Get-GitIgnorePatterns -WorkspacePath $WorkspaceRoot
    $Discovered = @{}
    $totalFiles = 0
    $totalKeys = 0
    foreach ($ProjectPath in $ProjectPaths) {
        if (-not (Test-Path $ProjectPath)) { continue }
        $Files = Get-ChildItem -Path $ProjectPath -Recurse -Include *.cs,*.razor -File
        foreach ($File in $Files) {
            $totalFiles++
            $Content = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
            $ResourceName = $null
            if ($File.Extension -eq ".razor") {
                $injectMatch = [regex]::Match($Content, '@inject\s+ILocalizationService<([\w\.]+)>\s+(\w+)')
                if ($injectMatch.Success) {
                    $ResourceName = $injectMatch.Groups[1].Value
                    $LocalizerVar = $injectMatch.Groups[2].Value
                    $pattern = '\b' + $LocalizerVar + '\.GetString(?:Auto)?\(\s*"([^"]+)"\s*\)'
                    $keyMatches = [regex]::Matches($Content, $pattern)
                    foreach ($km in $keyMatches) {
                        $key = $km.Groups[1].Value
                        $totalKeys++
                        if (-not $Discovered.ContainsKey($ResourceName)) { $Discovered[$ResourceName] = @{} }
                        $Discovered[$ResourceName][$key] = $true
                    }
                }
                $ResourceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
                $pattern = '\b\w+\.GetString(?:Auto)?\(\s*"([^"]+)"\s*\)'
                $keyMatches = [regex]::Matches($Content, $pattern)
                foreach ($km in $keyMatches) {
                    $key = $km.Groups[1].Value
                    $totalKeys++
                    if (-not $Discovered.ContainsKey($ResourceName)) { $Discovered[$ResourceName] = @{} }
                    $Discovered[$ResourceName][$key] = $true
                }
            }
            elseif ($File.Extension -eq ".cs") {
                # General pattern: match any occurrence of GetString or GetStringAuto with a string key
                $pattern = '\b\w+\.GetString(?:Auto)?\(\s*"([^"]+)"\s*[,)]'
                $keyMatches = [regex]::Matches($Content, $pattern)
                $ResourceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
                foreach ($km in $keyMatches) {
                    $key = $km.Groups[1].Value
                    $totalKeys++
                    if (-not $Discovered.ContainsKey($ResourceName)) { $Discovered[$ResourceName] = @{} }
                    $Discovered[$ResourceName][$key] = $true
                }
            }
        }
    }
    $ResourcesPath = Join-Path $WorkspaceRoot $ResourcesPath
    $resxData = @{}
    if (Test-Path $ResourcesPath) {
        $resxData = Get-ResxKeysAndValues -ProjectPaths $ProjectPaths
    }

    # Only output keys found in code, and for each, if a value exists in resx, use it, else empty string
    $Result = @{}
    foreach ($res in $Discovered.Keys) {
        $Result[$res] = @{}
        $resLower = $res.ToLowerInvariant()
        foreach ($key in $Discovered[$res].Keys) {
            $trimmedKey = $key.Trim()
            $val = ""
            if ($resxData.ContainsKey($resLower) -and $resxData[$resLower].ContainsKey($trimmedKey)) {
                $val = $resxData[$resLower][$trimmedKey]
            }
            $Result[$res][$key] = $val
        }
    }

    $Output = @{ type = "result"; payload = @{ DiscoveredKeys = $Result } }
    $Json = $Output | ConvertTo-Json -Depth 10 -Compress -EscapeHandling EscapeNonAscii
    Write-Output $Json
    exit 0
} catch {
    $ErrorPayload = @{
        Message = "Script failed: $($_.Exception.Message)"
        ScriptStackTrace = $_.ScriptStackTrace
        Exception = $_.Exception.ToString()
        DiscoveredKeys = @{}
    }
    $ErrorOutput = @{ type = "error"; payload = $ErrorPayload }
    $ErrorJson = $ErrorOutput | ConvertTo-Json -Depth 5 -Compress -EscapeHandling EscapeNonAscii
    Write-Output $ErrorJson
    exit 1
} 