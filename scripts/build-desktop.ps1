<#
Build the FreeChat desktop client on Windows.

A wrapper around upstream's own flow, not a replacement for it. The authority is
desktop/upstream/docs/building-win.md; this script checks the prerequisites that
are easy to get wrong and then calls upstream's scripts.

NOT VERIFIED, in two senses. No Windows machine was involved in producing this
repository, and prepare/win.bat compiles Qt, FFmpeg, OpenSSL and ~30 more
libraries -- tens of GB and hours. Beyond that, the environment this was written
in had no PowerShell at all, so even the SYNTAX of this file is unchecked. Read it
before running it, and treat a first failure as a toolchain gap or a typo here
rather than a broken overlay.

The one thing that catches everyone: these commands must run in a terminal where
the Visual Studio environment has been initialised with the OLD toolset. VS
2026's default v145 does not support Windows 7, so upstream requires
-vcvars_ver=14.44:

    %comspec% /k "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" -vcvars_ver=14.44

Usage, from that terminal:
    powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 [-Stage prepare|configure|build|all] [-Arch x64|x86]
#>
param(
    [ValidateSet('prepare', 'configure', 'build', 'all')]
    [string]$Stage = 'configure',
    [ValidateSet('x64', 'x86')]
    [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Up = Join-Path $Root 'desktop\upstream'

function Log  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "!   $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "error: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $Up 'Telegram\SourceFiles'))) {
    Die "desktop upstream missing - run: bash scripts/bootstrap.sh desktop"
}
if (-not (Test-Path (Join-Path $Up 'Telegram\SourceFiles\freechat\freechat_builtin.h'))) {
    Die "overlay not applied - run: bash scripts/apply-overlay.sh desktop"
}
$introPath = Join-Path $Up 'Telegram\SourceFiles\intro\intro_server_select.cpp'
if (-not (Select-String -Path $introPath -Pattern 'FreeChatBuiltin' -Quiet)) {
    Die "the auto-join hook is missing - run: bash scripts/apply-overlay.sh desktop"
}

# Submodule directories exist but are EMPTY until checked out, so test for a file
# inside one rather than for the directory.
if (-not (Test-Path (Join-Path $Up 'Telegram\lib_base\CMakeLists.txt'))) {
    Die @"
submodules are not checked out, and the build needs them:
      bash scripts/bootstrap.sh desktop --with-submodules
      Expect tens of GB.
"@
}

# The VS environment is what makes cl.exe and the right toolset available. Without
# it prepare/win.bat and configure.bat fail in ways that do not mention it.
if (-not $env:VSINSTALLDIR) {
    Die @"
the Visual Studio environment is not initialised in this terminal.

  Open a terminal with (adjust the edition/path for your install):

    %comspec% /k "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" -vcvars_ver=14.44

  -vcvars_ver=14.44 is required: VS 2026's default v145 toolset does not support
  Windows 7, which Telegram Desktop still targets. See
  desktop/upstream/docs/building-win.md.
"@
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is not on PATH. Install Git for Windows (https://git-scm.com/download/win)."
}

# Git Bash, not optional. bootstrap.sh and apply-overlay.sh are bash and there is
# no PowerShell equivalent of them on purpose -- they are the same code on all
# three systems, and a second implementation would be a second set of bugs. Git
# for Windows ships the bash that runs them, and a Telegram Desktop Windows build
# needs Git anyway. This check exists because the script's own error messages tell
# you to run `bash scripts/...`, which is a confusing instruction to receive on a
# machine with no bash.
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Die @"
bash is not on PATH, and the preparation steps need it.

  Install Git for Windows, then either
    * run those steps from the "Git Bash" shortcut, or
    * add C:\Program Files\Git\bin to PATH so `bash` works from here.

  Do NOT use WSL for this: a WSL checkout cannot see your Visual Studio
  installation, and the build needs MSVC on the Windows side.
"@
}

# Python 3 under any of its Windows names. A python.org install provides
# python.exe and the py.exe launcher and NOT python3, while the bash scripts call
# Python 30 times -- they resolve the name themselves (scripts/lib/portable.sh),
# and this check has to accept the same set or it rejects a machine that works.
# The version is asked of the interpreter rather than assumed from its name: a
# `python` that is Python 2 runs and then fails inside a script.
$pythonOk = $false
foreach ($cand in @(@('python3'), @('python'), @('py', '-3'))) {
    $exe = $cand[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $probeArgs = @()
    if ($cand.Count -gt 1) { $probeArgs += $cand[1..($cand.Count - 1)] }
    $probeArgs += @('-c', 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)')
    & $exe @probeArgs 2>$null
    if ($LASTEXITCODE -eq 0) { $pythonOk = $true; Log "python 3 found as: $($cand -join ' ')"; break }
}
if (-not $pythonOk) {
    Die @"
no working Python 3 found (tried python3, python, py -3).

  Install Python 3 from python.org and tick "Add python.exe to PATH" in the
  installer. Upstream's own build scripts expect Python 3.10 or newer on PATH.
"@
}

# Branding, including the API credentials configure requires. gramsrv does not
# validate either -- internal/rpc/auth.go:874 states there is no application
# registry and the values are only remembered -- so the defaults in freechat.env are
# fine for a self-hosted node and my.telegram.org is not involved.
# Same rules as scripts/lib/load_env.sh, so one freechat.env means the same
# thing to every script: freechat.env.example supplies the defaults and
# freechat.env overrides what it names; a quoted value is taken verbatim;
# an unquoted one loses an inline comment (whitespace then #) and its
# surrounding whitespace.
$brand = @{}
$brandFiles = @()
foreach ($name in 'freechat.env.example', 'freechat.env') {
    $path = Join-Path $Root $name
    if (-not (Test-Path $path)) { continue }
    $brandFiles += $name
    foreach ($line in Get-Content $path) {
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or
                                      ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        } else {
            $value = ($value -replace '\s#.*$', '').Trim()
        }
        $brand[$key] = $value
    }
}
if ($brandFiles.Count -eq 0) { Die "no freechat.env or freechat.env.example in $Root" }
$brandFile = $brandFiles -join ' + '
foreach ($key in 'FREECHAT_API_ID', 'FREECHAT_API_HASH') {
    if (-not $brand.ContainsKey($key) -or -not $brand[$key]) {
        Die "$key is not set in $brandFile"
    }
}
$apiId = $brand['FREECHAT_API_ID']
$apiHash = $brand['FREECHAT_API_HASH']

function Invoke-Prepare {
    Log 'preparing third-party libraries (hours, tens of GB)'
    Push-Location $Up
    try { & cmd /c 'Telegram\build\prepare\win.bat'; if ($LASTEXITCODE -ne 0) { Die 'prepare\win.bat failed' } }
    finally { Pop-Location }
}

function Invoke-Configure {
    # Reconfigure from scratch when the previous out\ was made for a different
    # tree, architecture or credentials: cmake caches all three, and a stale
    # cache aborts with a message about itself instead of reconfiguring.
    $out = Join-Path $Up 'out'
    $stamp = Join-Path $out '.freechat-configure-stamp'
    $want = "$Up|$apiId|$Arch"
    if ((Test-Path $out) -and ((Get-Content $stamp -ErrorAction SilentlyContinue) -ne $want)) {
        Log "previous configuration does not match - discarding $out"
        Remove-Item -Recurse -Force $out
    }

    Log "configuring for $Arch"
    Push-Location (Join-Path $Up 'Telegram')
    try {
        # configure.bat takes the architecture as a bare first argument; x86 is
        # its default and is spelled by omitting it.
        # NOT $args: that is a reserved automatic variable in PowerShell, and
        # assigning to it inside a function is a subtle way to get surprised.
        $configureArgs = @()
        if ($Arch -eq 'x64') { $configureArgs += 'x64' }
        $configureArgs += @('-D', "TDESKTOP_API_ID=$apiId", '-D', "TDESKTOP_API_HASH=$apiHash")
        & cmd /c "configure.bat $($configureArgs -join ' ')"
        if ($LASTEXITCODE -ne 0) { Die 'configure.bat failed' }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    Set-Content -Path $stamp -Value $want
}

function Invoke-Build {
    $sln = Join-Path $Up 'out\Telegram.slnx'
    if (-not (Test-Path $sln)) { Die "not configured yet - run this script with -Stage configure" }
    # msbuild when it is available, so the build can run unattended; otherwise
    # say what to open rather than pretending to build.
    $msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuild) {
        Log 'building with msbuild (Release)'
        & msbuild $sln /p:Configuration=Release /p:Platform=$Arch /m
        if ($LASTEXITCODE -ne 0) { Die 'msbuild failed' }
        Log "result under $Up\out\Release"
    } else {
        Warn "msbuild is not on PATH. Open $sln in Visual Studio 2026, select the"
        Warn 'Telegram project and Build > Build Telegram (Debug or Release).'
    }
}

switch ($Stage) {
    'prepare'   { Invoke-Prepare }
    'configure' { Invoke-Configure }
    'build'     { Invoke-Build }
    'all'       { Invoke-Prepare; Invoke-Configure; Invoke-Build }
}

Log 'done'
