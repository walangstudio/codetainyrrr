# setup.ps1 - interactive onboarding for codetainyrrr (Windows PowerShell)
# Walks through every option and writes .env

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# -- helpers -------------------------------------------------------------------

function Write-Header($text) {
    Write-Host ""
    Write-Host "-- $text " -ForegroundColor Cyan -NoNewline
    Write-Host ("-" * [Math]::Max(1, 46 - $text.Length)) -ForegroundColor DarkGray
}

function Write-Dim($text)  { Write-Host "  $text" -ForegroundColor DarkGray }
function Write-Ok($text)   { Write-Host "  [OK] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  [!]  $text" -ForegroundColor Yellow }

function QVal($v) {
    if ([string]::IsNullOrEmpty($v)) { return "" }
    return "`"$($v.Replace('\', '\\').Replace('"', '\"'))`""
}

function Normalize-PathInput($path) {
    # Accept both Windows (\) and Unix (/) paths, normalize to forward slashes for Docker
    if ($path -eq "" -or $path -eq $null) { return "" }
    return $path -replace '\\', '/'
}

$script:GoBack = $false

function Ask {
    param([string]$Question, [string]$Default = "", [switch]$IsPath)
    Write-Host $Question -ForegroundColor Yellow
    if ($Default -ne "") { Write-Host "  default: $Default" -ForegroundColor DarkGray }
    $input = Read-Host "  >"
    if ($input -eq "back" -or $input -eq "b" -or $input -eq "\") {
        $script:GoBack = $true
        return ""
    }
    $result = if ($input -eq "") { $Default } else { $input }
    if ($IsPath) { $result = Normalize-PathInput $result }
    return $result
}

function AskSecret {
    param([string]$Question, [string]$Current = "")
    Write-Host $Question -ForegroundColor Yellow
    if ($Current -ne "") { Write-Host "  (leave blank to keep existing value)" -ForegroundColor DarkGray }
    # Read-Host -AsSecureString does not consume piped stdin in PS 5.1;
    # fall back to plain Read-Host when input is redirected so tests work.
    if ($env:WIZARD_NO_TUI -eq "1" -or [Console]::IsInputRedirected) {
        $plain = Read-Host "  >"
    } else {
        $secure = Read-Host "  >" -AsSecureString
        $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ($plain -eq "back" -or $plain -eq "b" -or $plain -eq "\") {
        $script:GoBack = $true
        return ""
    }
    if ($plain -eq "" -and $Current -ne "") { return $Current }
    return $plain
}

function AskYN {
    param([string]$Question, [string]$Default = "n")
    $hint = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    Write-Host "$Question $hint" -ForegroundColor Yellow
    $input = Read-Host "  >"
    if ($input -eq "back" -or $input -eq "b" -or $input -eq "\") {
        $script:GoBack = $true
        return $false
    }
    if ($input -eq "") { $input = $Default }
    return $input.ToLower().StartsWith("y")
}

function Show-Menu {
    param([string]$Question, [hashtable[]]$Options)
    Write-Host $Question -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $key  = $Options[$i].Key
        $desc = $Options[$i].Desc
        Write-Host "  " -NoNewline
        Write-Host "$($i+1)" -ForegroundColor White -NoNewline
        Write-Host ") " -NoNewline
        Write-Host $key -ForegroundColor Green -NoNewline
        Write-Host " - $desc"
    }
    while ($true) {
        $input = Read-Host "  >"
        if ($input -eq "back" -or $input -eq "b" -or $input -eq "\") {
            $script:GoBack = $true
            return ""
        }
        if ($input -match '^\d+$') {
            $idx = [int]$input - 1
            if ($idx -ge 0 -and $idx -lt $Options.Count) { return $Options[$idx].Key }
        }
        if ($input -eq "") { return $Options[0].Key }
        Write-Dim "Invalid. Enter a number 1-$($Options.Count)."
    }
}

function Invoke-TuiMultiselect {
    param([string]$Title, [array]$Items, [string]$Existing = "")
    $picked = New-Object bool[] $Items.Count
    $existingArr = ($Existing -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Key.StartsWith("---")) { $picked[$i] = $false; continue }
        if ($Existing -ne "") {
            $picked[$i] = $existingArr -contains $Items[$i].Key
        } else {
            $picked[$i] = $Items[$i].Default -eq $true
        }
    }

    if ($env:WIZARD_NO_TUI -eq "1" -or [Console]::IsInputRedirected) {
        return Show-MultiSelectFallback $Title $Items $picked
    }

    $cursor = 0
    $n = $Items.Count
    while ($cursor -lt $n -and $Items[$cursor].Key.StartsWith("---")) { $cursor++ }
    $totalLines = $n + 3
    [Console]::CursorVisible = $false

    $renderLines = {
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "  Up/Down - SPACE toggle - A=all - N=none - Left/ESC back - Right/ENTER fwd" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $n; $i++) {
            if ($Items[$i].Key.StartsWith("---")) {
                Write-Host ("  -- {0}" -f $Items[$i].Key.Substring(3)).PadRight(70) -ForegroundColor DarkGray
                continue
            }
            $mark   = if ($picked[$i]) { "[x]" } else { "[ ]" }
            $prefix = if ($i -eq $cursor) { "  > " } else { "    " }
            $color  = if ($i -eq $cursor) { "Cyan" } else { "Gray" }
            Write-Host ("{0} {1}  {2,-16} {3}" -f $prefix, $mark, $Items[$i].Key, $Items[$i].Desc).PadRight(70) -ForegroundColor $color
        }
    }

    try {
        & $renderLines
        $startTop = [Console]::CursorTop - $totalLines
        while ($true) {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow' {
                    if ($cursor -gt 0) { $cursor-- }
                    while ($cursor -gt 0 -and $Items[$cursor].Key.StartsWith("---")) { $cursor-- }
                    while ($Items[$cursor].Key.StartsWith("---") -and $cursor -lt $n - 1) { $cursor++ }
                }
                'DownArrow' {
                    if ($cursor -lt $n - 1) { $cursor++ }
                    while ($cursor -lt $n - 1 -and $Items[$cursor].Key.StartsWith("---")) { $cursor++ }
                    while ($Items[$cursor].Key.StartsWith("---") -and $cursor -gt 0) { $cursor-- }
                }
                'Spacebar' { if (-not $Items[$cursor].Key.StartsWith("---")) { $picked[$cursor] = -not $picked[$cursor] } }
                'A' { for ($j = 0; $j -lt $n; $j++) { if (-not $Items[$j].Key.StartsWith("---")) { $picked[$j] = $true  } } }
                'N' { for ($j = 0; $j -lt $n; $j++) { if (-not $Items[$j].Key.StartsWith("---")) { $picked[$j] = $false } } }
                'LeftArrow'  { $script:GoBack = $true; break }
                'RightArrow' { break }
                'Escape'     { $script:GoBack = $true; break }
                'Enter'      { break }
            }
            if ($k.Key -eq 'Enter' -or $k.Key -eq 'Escape' -or $k.Key -eq 'LeftArrow' -or $k.Key -eq 'RightArrow') { break }
            [Console]::SetCursorPosition(0, $startTop)
            & $renderLines
        }
    } finally {
        [Console]::CursorVisible = $true
    }
    Write-Host ""
    if ($script:GoBack) { return "" }
    $chosen = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i].Key.StartsWith("---") -and $picked[$i]) { $chosen += $Items[$i].Key }
    }
    return $chosen -join ','
}

function Show-MultiSelectFallback {
    param([string]$Title, [array]$Items, [bool[]]$Picked)
    $numToIdx = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i].Key.StartsWith("---")) { $numToIdx += $i }
    }
    $nItems = $numToIdx.Count
    while ($true) {
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "  numbers (e.g. 1,3,5) toggle - 'a' all - 'n' none - Enter = confirm" -ForegroundColor DarkGray
        Write-Host ""
        $num = 1
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i].Key.StartsWith("---")) {
                Write-Host ("  -- {0}" -f $Items[$i].Key.Substring(3)) -ForegroundColor DarkGray
                continue
            }
            $mark = if ($Picked[$i]) { "[x]" } else { "[ ]" }
            Write-Host ("  {0} {1,2}) {2,-16} {3}" -f $mark, $num, $Items[$i].Key, $Items[$i].Desc) -ForegroundColor Gray
            $num++
        }
        $input = Read-Host "  >"
        if ($input -eq "") { break }
        if ($input -eq "back" -or $input -eq "b" -or $input -eq "\") {
            $script:GoBack = $true
            break
        }
        if ($input -eq 'a' -or $input -eq 'A') {
            for ($i = 0; $i -lt $Items.Count; $i++) { if (-not $Items[$i].Key.StartsWith("---")) { $Picked[$i] = $true  } }
        } elseif ($input -eq 'n' -or $input -eq 'N') {
            for ($i = 0; $i -lt $Items.Count; $i++) { if (-not $Items[$i].Key.StartsWith("---")) { $Picked[$i] = $false } }
        } else {
            foreach ($tok in ($input -split ',')) {
                $tok = $tok.Trim()
                if ($tok -match '^\d+$') {
                    $nidx = [int]$tok - 1
                    if ($nidx -ge 0 -and $nidx -lt $nItems) {
                        $idx = $numToIdx[$nidx]
                        $Picked[$idx] = -not $Picked[$idx]
                    }
                }
            }
        }
        Write-Host ""
    }
    if ($script:GoBack) { return "" }
    $chosen = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i].Key.StartsWith("---") -and $Picked[$i]) { $chosen += $Items[$i].Key }
    }
    return $chosen -join ','
}

# -- catalog.json + wizard.json ------------------------------------------------
$CatalogPath = Join-Path $ScriptDir "catalog.json"
if (-not (Test-Path $CatalogPath)) {
    Write-Host "catalog.json not found in $ScriptDir" -ForegroundColor Red
    exit 1
}
$Catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json

$WizardPath = Join-Path $ScriptDir "wizard.json"
if (-not (Test-Path $WizardPath)) {
    Write-Host "wizard.json not found in $ScriptDir" -ForegroundColor Red
    exit 1
}
$WizardDef = Get-Content $WizardPath -Raw | ConvertFrom-Json

function Get-WizPage($pageId, $key) {
    $page = $WizardDef.pages | Where-Object { $_.id -eq $pageId } | Select-Object -First 1
    if ($page -and $page.PSObject.Properties.Name -contains $key) { return $page.$key }
    return ""
}
function Get-WizField($pageId, $fieldId, $key) {
    $page = $WizardDef.pages | Where-Object { $_.id -eq $pageId } | Select-Object -First 1
    if (-not $page) { return "" }
    $field = $page.fields | Where-Object { $_.id -eq $fieldId } | Select-Object -First 1
    if ($field -and $field.PSObject.Properties.Name -contains $key) { return $field.$key }
    return ""
}

function Get-MergedCatalog {
    param([string]$Kind)  # "tools" or "plugins"
    $base = if ($Catalog.$Kind) { @($Catalog.$Kind) } else { @() }
    $userCatalogPath = Join-Path $ScriptDir "catalog.user.json"
    if (Test-Path $userCatalogPath) {
        $userCatalog = Get-Content $userCatalogPath -Raw | ConvertFrom-Json
        $userItems = if ($userCatalog.$Kind) { @($userCatalog.$Kind) } else { @() }
        $userKeys  = $userItems | ForEach-Object { $_.key }
        $merged    = @($base | Where-Object { $_.key -notin $userKeys }) + $userItems
        return $merged
    }
    return $base
}

function Get-MergedCatalogClis {
    $base = if ($Catalog.clis) { @($Catalog.clis) } else { @() }
    $userCatalogPath = Join-Path $ScriptDir "catalog.user.json"
    if (Test-Path $userCatalogPath) {
        $userCatalog = Get-Content $userCatalogPath -Raw | ConvertFrom-Json
        $userItems = if ($userCatalog.clis) { @($userCatalog.clis) } else { @() }
        $userKeys  = $userItems | ForEach-Object { $_.key }
        $merged    = @($base | Where-Object { $_.key -notin $userKeys }) + $userItems
        return $merged
    }
    return $base
}

function Invoke-TuiSingleSelect {
    param([string]$Question, [array]$Options, [string]$Current = "")
    if ($env:WIZARD_NO_TUI -eq "1" -or [Console]::IsInputRedirected) {
        return Show-Menu $Question $Options
    }
    $cursor = 0
    for ($i = 0; $i -lt $Options.Count; $i++) {
        if ($Options[$i].Key -eq $Current) { $cursor = $i; break }
    }
    $n = $Options.Count
    $totalLines = $n + 3
    [Console]::CursorVisible = $false
    $renderLines = {
        Write-Host "  $Question" -ForegroundColor Yellow
        Write-Host "  Up/Down navigate - Left/ESC back - Right/ENTER forward" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $n; $i++) {
            $key  = $Options[$i].Key
            $desc = $Options[$i].Desc
            if ($i -eq $cursor) {
                Write-Host ("  > {0,-16}  {1}" -f $key, $desc).PadRight(70) -ForegroundColor Cyan
            } else {
                Write-Host ("    {0,-16}  {1}" -f $key, $desc).PadRight(70) -ForegroundColor Gray
            }
        }
    }
    try {
        & $renderLines
        $startTop = [Console]::CursorTop - $totalLines
        while ($true) {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'    { if ($cursor -gt 0)    { $cursor-- } }
                'DownArrow'  { if ($cursor -lt $n-1) { $cursor++ } }
                'LeftArrow'  { $script:GoBack = $true; break }
                'RightArrow' { break }
                'Escape'     { $script:GoBack = $true; break }
                'Enter'      { break }
            }
            if ($k.Key -eq 'Enter' -or $k.Key -eq 'Escape' -or $k.Key -eq 'LeftArrow' -or $k.Key -eq 'RightArrow') { break }
            [Console]::SetCursorPosition(0, $startTop)
            & $renderLines
        }
    } finally {
        [Console]::CursorVisible = $true
    }
    Write-Host ""
    if ($script:GoBack) { return "" }
    return $Options[$cursor].Key
}

function Test-SupportsCli {
    param($item, [string]$cli)
    if ($item.PSObject.Properties.Name -contains "supported_clis") {
        $clis = @($item.supported_clis)
    } else {
        $clis = @("*")
    }
    return ($clis -contains "*" -or $clis -contains $cli)
}

function Build-MultiSelectOptions {
    param($items)
    $options = @()
    $seen = @{}
    foreach ($item in $items) {
        $cat = $item.category
        if (-not $seen.ContainsKey($cat)) {
            $options += @{ Key="---$cat"; Default=$false; Desc="" }
            $seen[$cat] = $true
        }
        $options += @{ Key=$item.key; Default=[bool]$item.default; Desc=$item.description }
    }
    return $options
}

# -- load existing .env as defaults -------------------------------------------
$Existing = @{}
$EnvFile  = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $k = $parts[0].Trim()
                $v = $parts[1].Trim().Trim('"')
                $Existing[$k] = $v
            }
        }
    }
}
function E($key, $fallback = "") {
    if ($Existing.ContainsKey($key)) { return $Existing[$key] } else { return $fallback }
}

# -- banner --------------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  +-------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |        codetainyrrr  -  setup             |" -ForegroundColor Cyan
Write-Host "  |   AI coding container - sandboxed - fast  |" -ForegroundColor Cyan
Write-Host "  +-------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This wizard creates your .env configuration file."
Write-Host "  Enter = accept default   \  or 'back' = previous step" -ForegroundColor DarkGray
Write-Host ""

if (Test-Path $EnvFile) {
    Write-Warn "Found existing .env - current values shown as defaults."
}

# Initialize all variables with defaults from .env
$CodingCLI          = E "CODING_CLI" "claude"
$ContainerName      = E "CONTAINER_NAME" "codetainyrrr"
$ProjectDir         = E "PROJECT_DIR" ""
$ExtraWorkspaces    = E "EXTRA_WORKSPACES" ""
$ClaudeDir          = E "CLAUDE_DIR" ""
$ClaudeJson         = E "CLAUDE_JSON" ""
$WireCcstatusline   = E "WIRE_CCSTATUSLINE" "true"
$AnthropicKey       = E "ANTHROPIC_API_KEY" ""
$OpenAIKey          = E "OPENAI_API_KEY" ""
$OpenRouterKey      = E "OPENROUTER_API_KEY" ""
$GeminiKey          = E "GEMINI_API_KEY" ""
$GitName            = E "GIT_AUTHOR_NAME" ""
$GitEmail           = E "GIT_AUTHOR_EMAIL" ""
# Migrate: add rtk to existing installs that predate it being an INSTALL_TOOLS option
$InstallTools = E "INSTALL_TOOLS" ""
if ($InstallTools -ne "" -and ($InstallTools -split ',') -notcontains "rtk") {
    $InstallTools = "rtk,$InstallTools"
}
$InstallPlugins     = E "INSTALL_PLUGINS" ""
$CcstatuslineConfig = E "CCSTATUSLINE_CONFIG" ""
$ZshExtraConfig     = E "ZSH_EXTRA_CONFIG" ""
$StarshipConfig     = E "STARSHIP_CONFIG" ""
$HostUID            = E "HOST_UID" "1000"
$HostGID            = E "HOST_GID" "1000"

$step = 1
$maxStep = $WizardDef.pages.Count

while ($step -le $maxStep) {
    $script:GoBack = $false

    switch ($step) {
        1 {
            # -- 1. AI CLI ---------------------------------------------------------
            Write-Header "Step 1/$maxStep - $(Get-WizPage 'cli' 'title')"
            Write-Dim (Get-WizPage 'cli' 'description')
            $cliItems = Get-MergedCatalogClis | ForEach-Object {
                @{ Key=$_.key; Desc="$($_.name) — $($_.description)" }
            }
            $_cliPrompt = Get-WizField 'cli' 'CODING_CLI' 'prompt'
            if ($_cliPrompt -eq "") { $_cliPrompt = "Pick your AI coding CLI:" }
            $result = Invoke-TuiSingleSelect $_cliPrompt $cliItems $CodingCLI
            if ($script:GoBack) { continue }
            if ($result -ne "") { $CodingCLI = $result }
            Write-Ok "CLI: $CodingCLI"

            $result = Ask (Get-WizField 'cli' 'CONTAINER_NAME' 'prompt') $ContainerName
            if ($script:GoBack) { continue }
            if ($result -ne "") { $ContainerName = $result }
            Write-Ok "Container: $ContainerName"
        }
        2 {
            # -- 2. Project directory ----------------------------------------------
            Write-Header "Step 2/$maxStep - $(Get-WizPage 'paths' 'title')"
            Write-Dim (Get-WizPage 'paths' 'description')
            Write-Dim (Get-WizPage 'paths' 'hint')
            $result = Ask (Get-WizField 'paths' 'PROJECT_DIR' 'prompt') $ProjectDir -IsPath
            if ($script:GoBack) { $step--; continue }
            if ($result -eq "") {
                Write-Host "  ERROR: PROJECT_DIR is required." -ForegroundColor Red
                continue
            }
            $ProjectDir = $result
            Write-Ok "Project: $ProjectDir"

            if (-not $script:GoBack -and (AskYN "Mount additional project folders?" "n")) {
                $result = Ask (Get-WizField 'paths' 'EXTRA_WORKSPACES' 'prompt') $ExtraWorkspaces -IsPath
                if ($script:GoBack) { continue }
                $ExtraWorkspaces = $result
            } elseif (-not $script:GoBack) {
                $ExtraWorkspaces = ""
            }
        }
        3 {
            # -- 3. Claude settings ------------------------------------------------
            Write-Header "Step 3/$maxStep - $(Get-WizPage 'claude_settings' 'title')"
            Write-Host "  Share project memories with Claude Desktop?" -ForegroundColor White
            Write-Dim "  $(Get-WizPage 'claude_settings' 'hint')"
            $shareDefault = if ($ClaudeDir -ne "") { "y" } else { "n" }
            if (AskYN "Share host ~/.claude?" $shareDefault) {
                if ($script:GoBack) { $step--; continue }
                Write-Dim "Both Windows and Unix path formats accepted."
                $result = Ask (Get-WizField 'claude_settings' 'CLAUDE_DIR' 'prompt') $ClaudeDir -IsPath
                if ($script:GoBack) { continue }
                $ClaudeDir = $result
                $result = Ask (Get-WizField 'claude_settings' 'CLAUDE_JSON' 'prompt') $ClaudeJson -IsPath
                if ($script:GoBack) { continue }
                $ClaudeJson = $result
                Write-Ok "Sharing: $ClaudeDir"
            } else {
                if ($script:GoBack) { $step--; continue }
                $ClaudeDir = ""
                $ClaudeJson = ""
                Write-Ok "Isolated: named volume"
            }

        }
        4 {
            # -- 4. API keys -------------------------------------------------------
            Write-Header "Step 4/$maxStep - $(Get-WizPage 'api_keys' 'title')"
            Write-Dim (Get-WizPage 'api_keys' 'description')
            $_hint = Get-WizField 'api_keys' 'ANTHROPIC_API_KEY' 'hint'
            if ($_hint -ne "") { Write-Dim "  $_hint" }
            $AnthropicKey = AskSecret (Get-WizField 'api_keys' 'ANTHROPIC_API_KEY' 'prompt') $AnthropicKey
            if ($script:GoBack) { $step--; continue }
            if ($AnthropicKey -ne "") { Write-Ok "Anthropic key set" }

            if (AskYN "Set additional provider keys? (OpenAI, OpenRouter, Gemini)" "n") {
                if ($script:GoBack) { continue }
                $OpenAIKey     = AskSecret (Get-WizField 'api_keys' 'OPENAI_API_KEY' 'prompt')     $OpenAIKey
                $OpenRouterKey = AskSecret (Get-WizField 'api_keys' 'OPENROUTER_API_KEY' 'prompt') $OpenRouterKey
                $GeminiKey     = AskSecret (Get-WizField 'api_keys' 'GEMINI_API_KEY' 'prompt')     $GeminiKey
            }
        }
        5 {
            # -- 5. Git identity ---------------------------------------------------
            Write-Header "Step 5/$maxStep - $(Get-WizPage 'git_identity' 'title')"
            Write-Dim (Get-WizPage 'git_identity' 'description')
            $result = Ask (Get-WizField 'git_identity' 'GIT_AUTHOR_NAME' 'prompt') $GitName
            if ($script:GoBack) { $step--; continue }
            $GitName = $result
            $result = Ask (Get-WizField 'git_identity' 'GIT_AUTHOR_EMAIL' 'prompt') $GitEmail
            if ($script:GoBack) { continue }
            $GitEmail = $result
            if ($GitName -ne "") { Write-Ok "Git: $GitName <$GitEmail>" }
        }
        6 {
            # -- 6. Dev Tools ------------------------------------------------------
            Write-Header "Step 6/$maxStep - $(Get-WizPage 'tools' 'title')"
            Write-Dim (Get-WizPage 'tools' 'description')
            $filteredTools = Get-MergedCatalog "tools" | Where-Object { Test-SupportsCli $_ $CodingCLI }
            $result = Invoke-TuiMultiselect "Pick dev tools" (Build-MultiSelectOptions $filteredTools) $InstallTools
            if ($script:GoBack) { $step--; continue }
            $InstallTools = $result
            if ($InstallTools -ne "") { Write-Ok "Tools: $InstallTools" } else { Write-Dim "  Tools: none" }
        }
        7 {
            # -- 7. Plugins --------------------------------------------------------
            Write-Header "Step 7/$maxStep - $(Get-WizPage 'plugins' 'title')"
            Write-Dim (Get-WizPage 'plugins' 'description')
            if ($CodingCLI -eq "claude") {
                # Re-inject wire-ccstatusline so re-runs restore checked state from WireCcstatusline.
                if ($WireCcstatusline -eq "true" -and ($InstallPlugins -split ',') -notcontains "wire-ccstatusline") {
                    $InstallPlugins = if ($InstallPlugins -ne "") { "wire-ccstatusline,$InstallPlugins" } else { "wire-ccstatusline" }
                }
                $filteredPlugins = Get-MergedCatalog "plugins" | Where-Object { Test-SupportsCli $_ $CodingCLI }
                $result = Invoke-TuiMultiselect "Pick plugins (Claude)" (Build-MultiSelectOptions $filteredPlugins) $InstallPlugins
                if ($script:GoBack) { $step--; continue }
                if ($result -match '(^|,)wire-ccstatusline(,|$)') {
                    $WireCcstatusline = "true"
                    $result = ($result -split ',' | Where-Object { $_ -ne "wire-ccstatusline" }) -join ','
                } else {
                    $WireCcstatusline = "false"
                }
                $InstallPlugins = $result
            } else {
                Write-Dim "Plugins are filtered by supported CLI. Add plugins for $CodingCLI in catalog.user.json."
                $filteredPlugins = Get-MergedCatalog "plugins" | Where-Object { Test-SupportsCli $_ $CodingCLI }
                $result = Invoke-TuiMultiselect "Pick plugins ($CodingCLI)" (Build-MultiSelectOptions $filteredPlugins) $InstallPlugins
                if ($script:GoBack) { $step--; continue }
                $WireCcstatusline = "false"
                $InstallPlugins = $result
            }
            if ($WireCcstatusline -eq "true") { Write-Ok "ccstatusline: wired" }
            if ($InstallPlugins -ne "") { Write-Ok "Plugins: $InstallPlugins" } else { Write-Dim "  Plugins: none" }
        }
        8 {
            # -- 8. Bring-your-own configs -----------------------------------------
            Write-Header "Step 8/$maxStep - $(Get-WizPage 'custom_configs' 'title')"
            Write-Dim "  $(Get-WizPage 'custom_configs' 'description')"
            Write-Dim "  $(Get-WizPage 'custom_configs' 'hint')"
            Write-Host ""
            $result = Ask (Get-WizField 'custom_configs' 'CCSTATUSLINE_CONFIG' 'prompt') $CcstatuslineConfig -IsPath
            if ($script:GoBack) { $step--; continue }
            $CcstatuslineConfig = $result
            $result = Ask (Get-WizField 'custom_configs' 'ZSH_EXTRA_CONFIG' 'prompt') $ZshExtraConfig -IsPath
            if ($script:GoBack) { continue }
            $ZshExtraConfig = $result
            $result = Ask (Get-WizField 'custom_configs' 'STARSHIP_CONFIG' 'prompt') $StarshipConfig -IsPath
            if ($script:GoBack) { continue }
            $StarshipConfig = $result
        }
    }

    if (-not $script:GoBack) { $step++ }
}

# -- 10. Summary ---------------------------------------------------------------
Write-Header "Summary"
Write-Host ""
$claudeDirDisplay = if ($ClaudeDir -ne "") { $ClaudeDir } else { "named volume (isolated)" }
$anthropicDisplay = if ($AnthropicKey -ne "") { "set" } else { "not set" }
$gitNameVal   = if ($GitName  -ne "") { $GitName }  else { "not set" }
$gitEmailVal  = if ($GitEmail -ne "") { $GitEmail } else { "not set" }
$toolsVal     = if ($InstallTools   -ne "") { $InstallTools }   else { "none" }
$pluginsVal   = if ($InstallPlugins -ne "") { $InstallPlugins } else { "none" }

Write-Host ("  {0,-24}{1}" -f "CLI:",           $CodingCLI)
Write-Host ("  {0,-24}{1}" -f "Container:",     $ContainerName)
Write-Host ("  {0,-24}{1}" -f "Project:",       $ProjectDir)
Write-Host ("  {0,-24}{1}" -f "Claude dir:",    $claudeDirDisplay)
Write-Host ("  {0,-24}{1}" -f "Anthropic key:", $anthropicDisplay)
Write-Host ("  {0,-24}{1}" -f "Git name:",      $gitNameVal)
Write-Host ("  {0,-24}{1}" -f "Git email:",     $gitEmailVal)
Write-Host ("  {0,-24}{1}" -f "Dev tools:",     $toolsVal)
Write-Host ("  {0,-24}{1}" -f "Plugins:",       $pluginsVal)
if ($CcstatuslineConfig -ne "") { Write-Host ("  {0,-24}{1}" -f "ccstatusline config:", $CcstatuslineConfig) }
if ($ZshExtraConfig     -ne "") { Write-Host ("  {0,-24}{1}" -f "zsh extra config:",    $ZshExtraConfig) }
if ($StarshipConfig     -ne "") { Write-Host ("  {0,-24}{1}" -f "starship config:",     $StarshipConfig) }
Write-Host ""

if (-not (AskYN "Write .env and continue?" "y")) {
    Write-Host "Aborted."
    exit 0
}

# -- 11. Write .env ------------------------------------------------------------
$cliKeys = (Get-MergedCatalogClis | ForEach-Object { $_.key }) -join " | "
$qProjectDir        = QVal $ProjectDir
$qExtraWorkspaces   = QVal $ExtraWorkspaces
$qClaudeDir         = QVal $ClaudeDir
$qClaudeJson        = QVal $ClaudeJson
$qGitName           = QVal $GitName
$qGitEmail          = QVal $GitEmail
$qCcstatuslineConfig = QVal $CcstatuslineConfig
$qZshExtraConfig    = QVal $ZshExtraConfig
$qStarshipConfig    = QVal $StarshipConfig

$envContent = @"
# codetainyrrr configuration
# Generated by setup.ps1 - edit manually or re-run setup.ps1 to update.

HOST_UID=$HostUID
HOST_GID=$HostGID

# -- AI CLI ------------------------------------------------------------------
# Options: $cliKeys
CODING_CLI=$CodingCLI
WIRE_CCSTATUSLINE=$WireCcstatusline
CONTAINER_NAME=$ContainerName

# -- Paths --------------------------------------------------------------------
PROJECT_DIR=$qProjectDir
EXTRA_WORKSPACES=$qExtraWorkspaces

# Claude config - leave blank to use an isolated named volume (recommended)
CLAUDE_DIR=$qClaudeDir
CLAUDE_JSON=$qClaudeJson

# -- API keys -----------------------------------------------------------------
ANTHROPIC_API_KEY=$AnthropicKey
OPENAI_API_KEY=$OpenAIKey
OPENROUTER_API_KEY=$OpenRouterKey
GEMINI_API_KEY=$GeminiKey

# -- Git identity -------------------------------------------------------------
GIT_AUTHOR_NAME=$qGitName
GIT_AUTHOR_EMAIL=$qGitEmail

# -- Dev tools ----------------------------------------------------------------
# Options: node,java,go,rust,python,deno,bun,dotnet,cpp,php,ruby,ts,pnpm,yarn,
#          react,react-native,expo,svelte,flutter,rtk,lazygit
INSTALL_TOOLS=$InstallTools

# -- Plugins ------------------------------------------------------------------
# Built-in: caveman,context-mode,claude-mem,claude-hud,ccusage,graphify,
#           mempalace,everything-claude-code,karpathy-skills
# Custom:   owner/repo  (Claude),  npm:pkg,  uv:pkg
INSTALL_PLUGINS=$InstallPlugins

# -- Bring-your-own configs ----------------------------------------------------
# Host paths => mounted read-only. Leave blank to use built-in defaults.
CCSTATUSLINE_CONFIG=$qCcstatuslineConfig
ZSH_EXTRA_CONFIG=$qZshExtraConfig
STARSHIP_CONFIG=$qStarshipConfig
"@

[System.IO.File]::WriteAllText($EnvFile, $envContent, [System.Text.UTF8Encoding]::new($false))
Write-Ok ".env written."

# -- 12. Build + start ---------------------------------------------------------
Write-Host ""
if (AskYN "Build the Docker image now? (required on first run, ~30s)" "y") {
    Write-Host ""
    & "$ScriptDir\run.ps1" -Build -Detach
    Write-Ok "Image built."
}

Write-Host ""
if (AskYN "Start the container now?" "y") {
    Write-Host ""
    & "$ScriptDir\run.ps1"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1" -ForegroundColor Cyan -NoNewline; Write-Host "         to start"
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1 connect" -ForegroundColor Cyan -NoNewline; Write-Host "  to attach another shell"
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1 stop" -ForegroundColor Cyan -NoNewline; Write-Host "     to stop the container"
if ($InstallPlugins -match "mempalace") {
    Write-Warn "mempalace: run 'mempalace init /workspace' inside the container on first use."
}
Write-Host ""
