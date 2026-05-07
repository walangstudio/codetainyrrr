# test-setup.ps1 - non-interactive tests for setup.ps1 navigation
# Feeds answers via stdin pipe, asserts .env output matches expectations.
# Usage: pwsh -File test-setup.ps1 [-Verbose]
#
# No Docker required. Creates temp dirs under $env:TEMP; cleans up on exit.
#Requires -Version 5.1

param([switch]$Verbose)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TmpBase   = Join-Path $env:TEMP "test-setup-ps1-$(Get-Random)"
New-Item -ItemType Directory -Path $TmpBase -Force | Out-Null

$Pass = 0; $Fail = 0

function Write-Pass($msg) { $script:Pass++; Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail($msg) { $script:Fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red  }
function Section($title)  { Write-Host ""; Write-Host "-- $title " -ForegroundColor Cyan }

function Get-EnvVal($file, $key) {
    if (-not (Test-Path $file)) { return "" }
    $line = Get-Content $file | Where-Object { $_ -match "^${key}=" } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -split '=', 2)[1].Trim().Trim('"')
}

function Assert-Env($envFile, $key, $expected) {
    $actual = Get-EnvVal $envFile $key
    if ($actual -eq $expected) {
        Write-Pass "${key}=${expected}"
    } else {
        Write-Fail "${key}: expected '$expected', got '$actual'"
        if ($Verbose) { Get-Content $envFile | ForEach-Object { Write-Host "    $_" } }
    }
}

function Assert-EnvContains($envFile, $key, $substr) {
    $actual = Get-EnvVal $envFile $key
    if ($actual -like "*$substr*") {
        Write-Pass "$key contains '$substr'"
    } else {
        Write-Fail "${key}: expected to contain '$substr', got '$actual'"
    }
}

# Run setup.ps1 with piped stdin in $dir; returns exit code; .env is in $dir\.env
function Invoke-Wizard($dir, [string[]]$answers) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Copy setup.ps1 into the temp dir so Set-Location $ScriptDir resolves there,
    # keeping .env writes isolated from the real project directory.
    $setupCopy = Join-Path $dir "setup.ps1"
    Copy-Item (Join-Path $ScriptDir "setup.ps1") $setupCopy -Force
    $logFile   = Join-Path $dir "wizard.log"
    $input_text = ($answers -join "`n") + "`n"
    $tmpInput  = Join-Path $dir "stdin.txt"
    [System.IO.File]::WriteAllText($tmpInput, $input_text, [System.Text.UTF8Encoding]::new($false))
    $env:WIZARD_NO_TUI = "1"
    try {
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
        $psArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$setupCopy`"")
        $proc = Start-Process $psExe -ArgumentList $psArgs `
            -WorkingDirectory $dir `
            -RedirectStandardInput $tmpInput `
            -RedirectStandardOutput $logFile `
            -RedirectStandardError (Join-Path $dir "wizard.err") `
            -Wait -PassThru -NoNewWindow
        if ($Verbose -and (Test-Path $logFile)) { Get-Content $logFile | ForEach-Object { Write-Host "  | $_" } }
        return $proc.ExitCode -eq 0
    } finally {
        Remove-Item env:WIZARD_NO_TUI -ErrorAction SilentlyContinue
    }
}

# Standard tail: confirm write, skip build, skip start
$TAIL = @("y", "n", "n")

# -- Test 1: Forward happy path --------------------------------------------------
Section "Test 1: forward happy path"

$d = Join-Path $TmpBase "t1"
$answers = @(
    ""             # step1 menu: default (claude)
    ""             # step1 container: default (codetainyrrr)
    "C:/tmp/proj1" # step2 project dir
    "n"            # step2 extra workspaces
    "n"            # step3 share claude
    ""             # step4 anthropic key (blank)
    "n"            # step4 extra provider keys
    "Alice"        # step5 git name
    "alice@test.com" # step5 git email
    ""             # step6 tools: confirm defaults
    ""             # step7 plugins: confirm defaults
    ""             # step8 ccstatusline config
    ""             # step8 zsh extra config
    ""             # step8 starship config
) + $TAIL

if (Invoke-Wizard $d $answers) {
    Assert-Env     "$d\.env" "CODING_CLI"       "claude"
    Assert-Env     "$d\.env" "CONTAINER_NAME"   "codetainyrrr"
    Assert-Env     "$d\.env" "PROJECT_DIR"       "C:/tmp/proj1"
    Assert-Env     "$d\.env" "GIT_AUTHOR_NAME"   "Alice"
    Assert-Env     "$d\.env" "GIT_AUTHOR_EMAIL"  "alice@test.com"
    Assert-Env     "$d\.env" "ANTHROPIC_API_KEY" ""
    Assert-EnvContains "$d\.env" "INSTALL_TOOLS" "rtk"
    Assert-EnvContains "$d\.env" "INSTALL_TOOLS" "node"
} else {
    Write-Fail "wizard exited non-zero"
    if ($Verbose) { Get-Content (Join-Path $d "wizard.log") }
}

# -- Test 2: Back from step 2 to step 1, change CLI -----------------------------
Section "Test 2: back from step 2 -> step 1, change CLI"

$d = Join-Path $TmpBase "t2"
$answers = @(
    "1"            # step1 menu: claude (explicit)
    "mybox"        # step1 container: mybox
    "back"         # step2 project dir -> BACK to step 1

    # step 1 reruns; mybox preserved as default
    "2"            # step1 menu: codex
    ""             # step1 container: keep "mybox"

    "C:/tmp/proj2" # step2 project dir
    "n"            # step2 extra workspaces
    "n"            # step3 share claude
    ""             # step4 anthropic key
    "n"            # step4 extra keys
    "Bob"          # step5 git name
    "bob@test.com" # step5 git email
    ""             # step6 tools
    ""             # step7 plugins
    ""             # step8 cc config
    ""             # step8 zsh config
    ""             # step8 starship config
) + $TAIL

if (Invoke-Wizard $d $answers) {
    Assert-Env "$d\.env" "CODING_CLI"     "codex"
    Assert-Env "$d\.env" "CONTAINER_NAME" "mybox"
    Assert-Env "$d\.env" "PROJECT_DIR"    "C:/tmp/proj2"
    Assert-Env "$d\.env" "GIT_AUTHOR_NAME" "Bob"
} else {
    Write-Fail "wizard exited non-zero"
}

# -- Test 3: Secret prompt back does not store "back" as API key ----------------
Section "Test 3: back in secret prompt does not corrupt API key"

$d = Join-Path $TmpBase "t3"
$answers = @(
    ""             # step1 menu
    ""             # step1 container
    "C:/tmp/proj3" # step2 project dir
    "n"            # step2 extra ws
    "n"            # step3 share claude
    "back"         # step4 anthropic key -> BACK to step 3

    # step3 reruns:
    "n"            # step3 share claude
    # step4 again:
    "sk-test-key"  # anthropic key
    "n"            # extra keys

    "Carol"        # step5 git name
    "carol@test.com" # step5 git email
    ""             # step6 tools
    ""             # step7 plugins
    ""             # step8 cc config
    ""             # step8 zsh config
    ""             # step8 starship config
) + $TAIL

if (Invoke-Wizard $d $answers) {
    $key = Get-EnvVal "$d\.env" "ANTHROPIC_API_KEY"
    if ($key -eq "back") {
        Write-Fail "ANTHROPIC_API_KEY stored literal 'back' -- secret back detection broken"
    } elseif ($key -eq "sk-test-key") {
        Write-Pass "ANTHROPIC_API_KEY='sk-test-key' (back navigated correctly)"
    } else {
        Write-Fail "ANTHROPIC_API_KEY unexpected: '$key'"
    }
} else {
    Write-Fail "wizard exited non-zero"
}

# -- Test 4: Forward-back-forward produces same .env as forward-only ------------
Section "Test 4: forward-back-forward .env matches forward-only"

function Make-CanonicalAnswers([string]$projPath, [string]$name, [string]$email) {
    return @(
        ""        # step1 menu
        ""        # step1 container
        $projPath # step2 project dir
        "n"       # step2 extra ws
        "n"       # step3 share claude
        ""        # step4 key
        "n"       # step4 extra keys
        $name     # step5 git name
        $email    # step5 git email
        ""        # step6 tools
        ""        # step7 plugins
        ""        # step8 cc config
        ""        # step8 zsh config
        ""        # step8 starship config
        "y"; "n"; "n"  # confirm write, skip build, skip start
    )
}

$dFwd = Join-Path $TmpBase "t4_fwd"
Invoke-Wizard $dFwd (Make-CanonicalAnswers "C:/tmp/proj4" "Eve" "eve@test.com") | Out-Null

$dFbf = Join-Path $TmpBase "t4_fbf"
$fbfAnswers = @(
    ""             # step1 menu
    ""             # step1 container
    "C:/tmp/proj4" # step2 project dir
    "n"            # step2 extra ws
    "n"            # step3 share claude
    ""             # step4 key
    "n"            # step4 extra keys
    "back"         # step5 git name -> BACK to step 4

    # step4 reruns:
    ""             # step4 key (blank = no change)
    "n"            # step4 extra keys

    "Eve"          # step5 git name
    "eve@test.com" # step5 git email
    ""             # step6 tools
    ""             # step7 plugins
    ""             # step8 cc config
    ""             # step8 zsh config
    ""             # step8 starship config
) + $TAIL
Invoke-Wizard $dFbf $fbfAnswers | Out-Null

$keys = @("CODING_CLI","CONTAINER_NAME","PROJECT_DIR","GIT_AUTHOR_NAME","GIT_AUTHOR_EMAIL","INSTALL_TOOLS","INSTALL_PLUGINS","ANTHROPIC_API_KEY")
foreach ($k in $keys) {
    $vFwd = Get-EnvVal "$dFwd\.env" $k
    $vFbf = Get-EnvVal "$dFbf\.env" $k
    if ($vFwd -eq $vFbf) {
        Write-Pass "fwd==fbf: ${k}='$vFwd'"
    } else {
        Write-Fail "${k} mismatch: fwd='$vFwd' fbf='$vFbf'"
    }
}

# -- Cleanup + summary ----------------------------------------------------------
Remove-Item -Recurse -Force $TmpBase -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "--------------------------------------------------------------------"
Write-Host "  Results: $Pass passed, $Fail failed"
Write-Host "--------------------------------------------------------------------"
if ($Fail -gt 0) { exit 1 } else { exit 0 }
