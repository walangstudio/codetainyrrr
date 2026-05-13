# Codetainyrrr e2e test runner.
# Spins a named container per test, drives orchestrator with env vars, waits
# for ready file, then verifies expected paths exist.

param(
  [string]$Image    = "codetainyrrr:e2e",
  [int]   $Timeout  = 300,
  [string]$Phase    = "all"
)

$ErrorActionPreference = "Continue"
$script:results = New-Object System.Collections.ArrayList

function Wait-Ready {
  param([string]$Name, [int]$TimeoutSec)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    docker exec $Name test -f /tmp/codetainyrrr.ready 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return "READY" }
    $running = docker inspect -f '{{.State.Running}}' $Name 2>$null
    if ($running -ne 'true') { return "EXITED" }
    Start-Sleep -Seconds 4
  }
  return "TIMEOUT"
}

function Check-Path {
  param([string]$Name, [string]$Path)
  docker exec $Name bash -c "test -e $Path -o -L $Path" 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Add-Result {
  param([string]$Id, [string]$Status, [string]$Message)
  $script:results.Add(@{ Id = $Id; Status = $Status; Message = $Message }) | Out-Null
  $color = "White"
  if ($Status -eq "PASS") { $color = "Green" }
  elseif ($Status -eq "FAIL") { $color = "Red" }
  elseif ($Status -eq "SKIP") { $color = "DarkYellow" }
  Write-Host ("  {0} - {1}" -f $Status, $Message) -ForegroundColor $color
}

function Run-Test {
  param(
    [string]   $Id,
    [string]   $Description,
    [string]   $Cli      = "claude",
    [string]   $Tools    = "",
    [string]   $Plugins  = "",
    [string[]] $Expected = @(),
    [string]   $Volume   = "",
    [int]      $TimeoutSec = $Timeout,
    [switch]   $ShouldFail
  )
  $name = "ct_e2e_" + $Id.ToLower()
  Write-Host ""
  Write-Host ("--- {0} : {1} ---" -f $Id, $Description) -ForegroundColor Cyan
  Write-Host ("    CLI={0}  TOOLS=[{1}]  PLUGINS=[{2}]" -f $Cli, $Tools, $Plugins)

  docker rm -f $name 2>$null | Out-Null

  $args = @(
    "run", "-d", "--name", $name,
    "-e", "CODING_CLI=$Cli",
    "-e", "INSTALL_TOOLS=$Tools",
    "-e", "INSTALL_PLUGINS=$Plugins",
    "-e", "HOST_UID=1000", "-e", "HOST_GID=1000"
  )
  if ($Volume -ne "") {
    $args += @("-v", ($Volume + ":/home/dev"))
  }
  # Use the default entrypoint shim (entrypoint.sh) so handlers run as the dev
  # user via `gosu`. Bypassing the shim by overriding --entrypoint masks
  # dev-only bugs — e.g. sdkman bailing on the Dockerfile-pre-created
  # /home/dev/.sdkman stub (only exists for dev, not root). Tests should
  # mirror real-user invocation.
  $args += @($Image, "--daemon")

  $null = & docker @args
  if ($LASTEXITCODE -ne 0) {
    Add-Result $Id "FAIL" "docker run failed"
    return
  }

  $state = Wait-Ready -Name $name -TimeoutSec $TimeoutSec

  if ($ShouldFail) {
    if ($state -eq "EXITED") {
      Add-Result $Id "PASS" "expected failure observed"
    } else {
      Add-Result $Id "FAIL" ("expected failure, got state=" + $state)
      Write-Host (docker logs --tail 30 $name 2>&1)
    }
    docker rm -f $name 2>$null | Out-Null
    return
  }

  if ($state -ne "READY") {
    Add-Result $Id "FAIL" ("container state=" + $state)
    Write-Host (docker logs --tail 40 $name 2>&1)
    docker rm -f $name 2>$null | Out-Null
    return
  }

  $missing = @()
  foreach ($p in $Expected) {
    if (-not (Check-Path $name $p)) { $missing += $p }
  }
  if ($missing.Count -gt 0) {
    Add-Result $Id "FAIL" ("missing: " + ($missing -join ", "))
  } else {
    $count = $Expected.Count
    Add-Result $Id "PASS" ("$count binaries verified")
  }

  docker rm -f $name 2>$null | Out-Null
}

# ─── Phase 1 ────────────────────────────────────────────────────────────────
function Phase1 {
  Write-Host "`n====== PHASE 1: HANDLER COVERAGE ======" -ForegroundColor Yellow
  Run-Test -Id H1  -Description "shell-pipe (CLI=claude)"            -Cli claude -Expected @('/home/dev/.local/bin/claude')
  Run-Test -Id H2  -Description "uv (CLI=aider)"                     -Cli aider  -Expected @('/home/dev/.local/bin/uv','/home/dev/.local/bin/aider')
  Run-Test -Id H3  -Description "nvm (tool=node)"                    -Tools node -Expected @('/home/dev/.nvm/nvm.sh')
  Run-Test -Id H4  -Description "go (tool=go)"                       -Tools go   -Expected @('/home/dev/go/sdk/bin/go')
  Run-Test -Id H5  -Description "sdkman (tool=java)"                 -Tools java -Expected @('/home/dev/.sdkman/candidates/java/current/bin/java') -TimeoutSec 480
  Run-Test -Id H6  -Description "gh-release (tool=lazygit)"          -Tools lazygit -Expected @('/home/dev/.local/bin/lazygit')
  Run-Test -Id H7  -Description "corepack (tool=pnpm, pulls node)"   -Tools pnpm -Expected @('/home/dev/.nvm/nvm.sh')
  Run-Test -Id H8  -Description "python composite"                   -Tools python -Expected @('/home/dev/.local/bin/uv')
  Run-Test -Id H9  -Description "shell-pipe (tool=rust)"             -Tools rust -Expected @('/home/dev/.cargo/bin/cargo','/home/dev/.cargo/bin/rustc')
  Run-Test -Id H10 -Description "shell-pipe (tool=bun)"              -Tools bun  -Expected @('/home/dev/.bun/bin/bun')
  Run-Test -Id H11 -Description "shell-pipe (tool=deno)"             -Tools deno -Expected @('/home/dev/.deno/bin/deno')
  Run-Test -Id H12 -Description "shell-pipe (tool=dotnet)"           -Tools dotnet -Expected @('/home/dev/.dotnet/dotnet')
}

# ─── Phase 2 ────────────────────────────────────────────────────────────────
function Phase2 {
  Write-Host "`n====== PHASE 2: DEPENDENCY RESOLUTION ======" -ForegroundColor Yellow
  Run-Test -Id D1 -Description "expo pulls node"                          -Tools expo -Expected @('/home/dev/.nvm/nvm.sh')
  Run-Test -Id D2 -Description "ts+react+expo: one node, three npm pkgs" -Tools "ts,react,expo" -Expected @('/home/dev/.nvm/nvm.sh') -TimeoutSec 480
  Run-Test -Id D3 -Description "aider+mempalace+graphify: one uv, three uv pkgs" -Cli aider -Plugins "mempalace,graphify" -Expected @('/home/dev/.local/bin/aider','/home/dev/.local/bin/mempalace','/home/dev/.local/bin/graphify') -TimeoutSec 480
}

# ─── Phase 3 ────────────────────────────────────────────────────────────────
function Phase3 {
  Write-Host "`n====== PHASE 3: RECONFIGURE ======" -ForegroundColor Yellow
  $vol = "ct_e2e_reconf_vol"
  docker volume rm -f $vol 2>$null | Out-Null

  Run-Test -Id R1 -Description "initial: claude+node"   -Tools node       -Volume $vol -Expected @('/home/dev/.nvm/nvm.sh','/home/dev/.local/bin/claude')
  Run-Test -Id R2 -Description "add ts (reuse node)"    -Tools "node,ts"  -Volume $vol -Expected @('/home/dev/.nvm/nvm.sh')
  Add-Result "R3" "SKIP" "entrypoint only adds; uninstall covered by setup-time reconcile"
  Run-Test -Id R4 -Description "add expo (reuse node)"  -Tools "node,expo" -Volume $vol -Expected @('/home/dev/.nvm/nvm.sh')

  docker volume rm -f $vol 2>$null | Out-Null
}

# ─── Phase 4 ────────────────────────────────────────────────────────────────
function Phase4 {
  Write-Host "`n====== PHASE 4: CLI SWAP ======" -ForegroundColor Yellow
  $vol = "ct_e2e_swap_vol"
  docker volume rm -f $vol 2>$null | Out-Null

  Run-Test -Id S1 -Description "initial CLI=claude"        -Cli claude -Volume $vol -Expected @('/home/dev/.local/bin/claude')
  Run-Test -Id S2 -Description "swap to CLI=codex (pulls node)" -Cli codex -Volume $vol -Expected @('/home/dev/.local/bin/claude','/home/dev/.nvm/nvm.sh')

  docker volume rm -f $vol 2>$null | Out-Null
}

# ─── Phase 5 ────────────────────────────────────────────────────────────────
function Phase5 {
  Write-Host "`n====== PHASE 5: IDEMPOTENCY + EDGE CASES ======" -ForegroundColor Yellow
  $vol = "ct_e2e_idem_vol"
  docker volume rm -f $vol 2>$null | Out-Null

  Run-Test -Id I1a -Description "first install"          -Tools node -Volume $vol -Expected @('/home/dev/.nvm/nvm.sh')
  $start = Get-Date
  Run-Test -Id I1b -Description "second run = no-op"     -Tools node -Volume $vol -Expected @('/home/dev/.nvm/nvm.sh')
  $sec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
  Write-Host ("    Idempotent run took {0}s (expected < 30s)" -f $sec)

  Run-Test -Id I2 -Description "empty selections, only CLI" -Tools "" -Plugins "" -Expected @('/home/dev/.local/bin/claude')
  Run-Test -Id I3 -Description "invalid tool key 'typo123'" -Tools "typo123" -ShouldFail

  docker volume rm -f $vol 2>$null | Out-Null
}

# ─── Driver ─────────────────────────────────────────────────────────────────
$started = Get-Date
switch ($Phase) {
  "1" { Phase1 }
  "2" { Phase2 }
  "3" { Phase3 }
  "4" { Phase4 }
  "5" { Phase5 }
  "all" { Phase1; Phase2; Phase3; Phase4; Phase5 }
}
$totalMin = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)

Write-Host "`n====== TEST SUMMARY ======" -ForegroundColor Yellow
$pass = ($script:results | Where-Object { $_.Status -eq "PASS" }).Count
$fail = ($script:results | Where-Object { $_.Status -eq "FAIL" }).Count
$skip = ($script:results | Where-Object { $_.Status -eq "SKIP" }).Count

foreach ($r in $script:results) {
  $color = "White"
  if ($r.Status -eq "PASS") { $color = "Green" }
  elseif ($r.Status -eq "FAIL") { $color = "Red" }
  elseif ($r.Status -eq "SKIP") { $color = "DarkYellow" }
  Write-Host ("{0,-6} {1,-6} {2}" -f $r.Id, $r.Status, $r.Message) -ForegroundColor $color
}

Write-Host ""
Write-Host ("{0} PASS, {1} FAIL, {2} SKIP   (elapsed: {3}m)" -f $pass, $fail, $skip, $totalMin) -ForegroundColor Yellow
if ($fail -gt 0) { exit 1 } else { exit 0 }
