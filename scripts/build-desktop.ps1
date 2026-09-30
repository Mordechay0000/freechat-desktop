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
    powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 [-Stage doctor|prepare|configure|build|all] [-Arch auto|x64|x86|arm64]
#>
param(
    [ValidateSet('doctor', 'prepare', 'configure', 'build', 'all')]
    [string]$Stage = 'configure',
    [ValidateSet('auto', 'x64', 'x86', 'arm64')]
    [string]$Arch = 'auto'
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Up = Join-Path $Root 'desktop\upstream'

# Output goes to stdout and stderr, never to Write-Host.
#
# This is why the script looked like it printed nothing. Write-Host writes
# through the console host instead of to the process's stdout, and two situations
# that both happen here lose exactly that:
#
#   Git Bash (mintty)   the README tells people to run the bash steps from Git
#                       Bash, and PowerShell started from there prints into
#                       nothing: mintty is a pty, and console-host writes do not
#                       reach it. The script would fail one of its checks and the
#                       window would stay empty.
#   any redirection     in Windows PowerShell 5.1 -- the powershell.exe on every
#                       Windows install -- `> log.txt` captures stdout and NOT
#                       Write-Host, so the screen showed text while the log came
#                       out empty. PowerShell 7 changed this, which is why the
#                       same script looks fine under pwsh.
#
# Colors are the price, and they are not worth a build that cannot be read or
# logged. Errors go to stderr so a redirected run still puts the failure on the
# screen.
function Say  { param($m) [Console]::Out.WriteLine($m); [Console]::Out.Flush() }
function Log  { param($m) Say "==> $m" }
function Warn { param($m) Say "!   $m" }
function Die  {
    param($m)
    [Console]::Error.WriteLine("error: $m")
    [Console]::Error.Flush()
    exit 1
}

# Anything that throws regardless -- a missing command, $ErrorActionPreference
# doing its job -- is printed through the same channel, because PowerShell's own
# rendering of an error is a console-host write too (see above). Without this, a
# crash is silent in the very environment that needs the message most.
trap {
    [Console]::Error.WriteLine('error: ' + $_.Exception.Message)
    try { [Console]::Error.WriteLine('  ' + $_.InvocationInfo.PositionMessage) } catch { }
    exit 1
}

# The architecture, and the three tools that each spell it differently.
#
# Windows has no universal binary: no lipo, and ARM64X -- a single PE carrying
# both an Arm64 and an x64 view -- runs on Windows on Arm only, so it does not
# replace an x64 build either. A Windows build is one architecture, and upstream
# supports three of them:
#
#   -Arch   $env:Platform   configure.bat   msbuild   libraries
#   x86     x86             x86             Win32     Libraries
#   x64     x64             x64             x64       Libraries\win64
#   arm64   arm64           arm             ARM64     Libraries
#
# `auto`, the default, reads the environment, and that is not laziness: prepare.py
# takes its architecture from exactly $env:Platform (set by the Visual Studio
# prompt), so asking for x64 while the prompt is ARM64 builds the libraries for
# one architecture and the app for the other, which fails while linking.
function Resolve-Arch {
    param([string]$Requested)
    if ($Requested -ne 'auto') {
        $script:ArchOrigin = 'requested'
        return $Requested
    }
    foreach ($candidate in @($env:Platform, $env:VSCMD_ARG_TGT_ARCH)) {
        if (-not $candidate) { continue }
        $value = $candidate.ToLower()
        if ($value -eq 'amd64') { $value = 'x64' }
        if (@('x86', 'x64', 'arm64') -contains $value) {
            $script:ArchOrigin = "from the Visual Studio environment ($candidate)"
            return $value
        }
    }
    $script:ArchOrigin = 'the default - no architecture in the environment'
    return 'x64'
}

# What configure.bat wants: it takes the architecture as a bare argument, and its
# run_cmake.py maps 'arm' to -AARM64.
function Get-ConfigureArch {
    if ($Arch -eq 'arm64') { return 'arm' }
    return $Arch
}

# What msbuild wants. The 32-bit platform is called Win32 there, not x86.
function Get-MsbuildPlatform {
    if ($Arch -eq 'arm64') { return 'ARM64' }
    if ($Arch -eq 'x86') { return 'Win32' }
    return $Arch
}

$RequestedArch = $Arch
$Arch = Resolve-Arch $Arch

# The prompt that has to be used, which depends on the architecture: vcvars32 and
# vcvars64 for x86 and x64, and the ARM64 one for arm64. prepare.py refuses to
# start without $env:Platform from one of them, so this is the first thing to fix
# when the prepare stage fails immediately.
$VcvarsScript = 'vcvars64.bat'
$VcvarsArch = ''
if ($Arch -eq 'x86') { $VcvarsScript = 'vcvars32.bat' }
if ($Arch -eq 'arm64') { $VcvarsScript = 'vcvarsall.bat'; $VcvarsArch = 'arm64 ' }
$VcvarsHint = "%comspec% /k `"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\$VcvarsScript`" $VcvarsArch-vcvars_ver=14.44"

# Printed before any check runs, so that "the script did nothing" can never mean
# "the script said nothing": the first line is on screen whatever happens next.
Log "FreeChat desktop - windows, $Arch ($ArchOrigin), stage $Stage"
Say "    root $Root"

# --- helpers the checks and the doctor both need ---------------------------
#
# Defined before the checks below, because -Stage doctor runs before them: its
# whole point is to report a missing prerequisite instead of dying on it, so it
# cannot be behind the checks that die.

# One line per submodule that is not fully checked out, from git itself.
function Get-SubmoduleProblems {
    $bad = @()
    foreach ($line in (& git -C $Up submodule status --recursive 2>$null)) {
        if ($line -notmatch '^\s') { $bad += $line.Trim() }
    }
    return $bad
}

# Where prepare\win.bat installs Qt for this architecture: upstream puts x64 in
# Libraries\win64 and x86 and arm64 in Libraries (variables.cmake: build_win64 ->
# ../Libraries/win64, everything else -> ../Libraries), and prepare.py installs
# into the same root. A tree prepared for one of them is invisible to another in
# a way that looks exactly like "no Qt at all", so the check below says which
# root it wanted.
function Get-PreparedQtRoot {
    if ($Arch -eq 'x64') { return (Join-Path $Root 'desktop\Libraries\win64') }
    return (Join-Path $Root 'desktop\Libraries')
}

# The Qt install under a libraries root, found by what the build needs -- a Qt6
# cmake config -- and not by the version in the directory name, which follows
# upstream's qt_version.py.
function Find-PreparedQt {
    param([string]$LibrariesRoot)
    $found = Get-ChildItem -Path (Join-Path $LibrariesRoot 'Qt-*') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'lib\cmake\Qt6\Qt6Config.cmake') }
    if ($found) { return $found[0].FullName }
    return $null
}

# One line of the doctor's report. The marker is a column of its own so that the
# values line up whether or not a line is a problem -- an unaligned report is one
# nobody scans, and this output is the whole point of the stage.
function Report {
    param([string]$Label, [string]$Value, [switch]$Blocking)
    $mark = ' '
    if ($Blocking) { $mark = '!' }
    Say ("  {0}{1,-15} {2}" -f $mark, $Label, $Value)
}

# Everything the stages check, in one place, changing nothing.
#
# The bash side has the same stage, and the reason is the same on both: the two
# ways this script failed both looked like nothing at all -- output that never
# reached the console, and a check that died with a message nobody could see.
# Read-only on purpose, and it exits 1 when something must be dealt with first,
# so `-Stage doctor` followed by `-Stage all` means something.
function Invoke-Doctor {
    $blockers = 0
    Say 'FreeChat desktop - preparation and toolchain'
    Say ''
    Report 'host' "windows $([System.Environment]::OSVersion.Version)"
    Report 'powershell' "$($PSVersionTable.PSVersion)"

    # The tree itself. Checked here rather than assumed, because doctor also has
    # to work on a machine where the first thing to run is the diagnostic.
    if (Test-Path (Join-Path $Up 'Telegram\SourceFiles')) {
        Report 'upstream' 'present'
    } else {
        Report 'upstream' 'missing - bash scripts/bootstrap.sh desktop' -Blocking
        $blockers++
    }
    if (Test-Path (Join-Path $Up 'Telegram\SourceFiles\freechat\freechat_builtin.h')) {
        Report 'overlay' 'applied'
    } else {
        Report 'overlay' 'not applied - bash scripts/apply-overlay.sh desktop' -Blocking
        $blockers++
    }

    Report 'architecture' "$Arch ($ArchOrigin) - libraries under $(Get-PreparedQtRoot)"
    Report 'spellings' "configure.bat $(Get-ConfigureArch), msbuild $(Get-MsbuildPlatform)"
    try {
        $drive = Get-Item $Root
        $freeGb = [math]::Round((Get-PSDrive $drive.PSDrive.Name).Free / 1GB)
        Report 'disk free' "${freeGb}GB on $($drive.PSDrive.Name):"
    } catch {
        Report 'disk free' 'unknown'
    }

    # The one prerequisite that is not on PATH, and the reason prepare\win.bat
    # and configure.bat fail without mentioning it.
    if ($env:VSINSTALLDIR) {
        Report 'visual studio' "initialised ($env:VSINSTALLDIR)"
    } else {
        Report 'visual studio' 'NOT initialised - prepare and configure cannot run' -Blocking
        Say  "                    open a terminal with the OLD toolset first ($Arch):"
        Say  "                      $VcvarsHint"
        $blockers++
    }

    foreach ($tool in 'git', 'bash') {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Report $tool "$($cmd.Source)"
        } else {
            Report $tool 'not on PATH' -Blocking
            $blockers++
        }
    }

    $python = $null
    foreach ($cand in @(@('python3'), @('python'), @('py', '-3'))) {
        $exe = $cand[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $probe = @()
        if ($cand.Count -gt 1) { $probe += $cand[1..($cand.Count - 1)] }
        $probe += @('-c', 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)')
        & $exe @probe 2>$null
        if ($LASTEXITCODE -eq 0) { $python = ($cand -join ' '); break }
    }
    if ($python) {
        Report 'python 3' $python
    } else {
        Report 'python 3' 'not found (tried python3, python, py -3)' -Blocking
        $blockers++
    }

    # Prepared state, read-only: doctor reports, it does not repair.
    $qt = Find-PreparedQt (Get-PreparedQtRoot)
    if ($qt) {
        Report 'prepared Qt' $qt
    } else {
        Report 'prepared Qt' 'missing or half-written - -Stage prepare (~35GB, hours)' -Blocking
        $blockers++
    }

    # The one hazard of sharing a tree with a macOS build: x86 and arm64 use the
    # same Libraries\ root that the macOS stages build in, and each stage starts by
    # deleting its own directory. Reported here because it is a fact about the
    # tree, not a failure -- the macOS build already produced stays usable.
    if ($Arch -ne 'x64' -and (Find-PreparedQt (Join-Path $Root 'desktop\Libraries\local'))) {
        Report 'macOS libraries' 'present in Libraries\ - a prepare here rebuilds them for Windows'
    }

    if (Test-Path (Join-Path $Up '.git')) {
        $subs = Get-SubmoduleProblems
        if ($subs.Count -eq 0) {
            Report 'submodules' 'complete'
        } else {
            Report 'submodules' "$($subs.Count) problem(s):" -Blocking
            foreach ($s in $subs) { Say "                    $s" }
            $blockers++
        }
    } else {
        Report 'submodules' 'cannot check - no upstream checkout'
    }

    if (Test-Path (Join-Path $Up 'out\Telegram.slnx')) {
        Report 'build output' 'configured (out\Telegram.slnx)'
    } else {
        Report 'build output' 'not configured - -Stage configure'
    }
    $stamp = Join-Path $Up 'out\.freechat-configure-stamp'
    if (Test-Path $stamp) {
        Report 'stamp' "$(Get-Content $stamp -ErrorAction SilentlyContinue)"
    }

    Say ''
    if ($blockers -gt 0) {
        Say "  $blockers problem(s) above must be dealt with before a build."
        exit 1
    }
    Say '  nothing blocking. next: -Stage all'
}

# Doctor runs before the checks that die, by design: its job is to report what is
# missing, including the things the checks below treat as fatal.
if ($Stage -eq 'doctor') {
    Invoke-Doctor
    exit 0
}

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
      Expect tens of GB. If that was interrupted, run it again: git continues and
      skips the submodules it already has.
"@
}

# Ask git whether every submodule is really there, not merely that one file is.
#
# The test above catches "nothing was fetched at all". What it does not catch is
# the expensive half-way state: a fetch interrupted by a dropped network leaves
# directories that exist and are EMPTY, and the build then fails hours later
# inside a missing header nobody deleted on purpose. `git submodule status
# --recursive` is git's own answer (a leading '-' means not initialized, '+' a
# different commit than recorded), and `git submodule update --init --recursive`
# is both the repair and the resume -- it fetches what is missing and skips what
# is present. Same rule as the bash side: bootstrap.sh, build-desktop.sh and this
# script all ask git rather than trusting an existing directory.
function Assert-Submodules {
    $bad = Get-SubmoduleProblems
    if ($bad.Count -eq 0) { return }
    Warn 'submodules are incomplete:'
    foreach ($b in $bad) { Warn "  $b" }
    Log 'running git submodule update --init --recursive (git skips what is present)'
    & git -C $Up submodule update --init --recursive --depth 1
    if ($LASTEXITCODE -ne 0) {
        Die @"
git submodule update failed. A dropped network is the usual cause.
      Run this script again: git resumes and skips the submodules it already has.
"@
    }
    $left = Get-SubmoduleProblems
    if ($left.Count -gt 0) {
        $joined = $left -join "`n"
        Die @"
submodules are still incomplete after the repair:
$joined
      Repair by hand: git -C $Up submodule update --init --recursive
"@
    }
    Log 'submodules verified and complete'
}

Assert-Submodules

# The VS environment is what makes cl.exe and the right toolset available. Without
# it prepare/win.bat and configure.bat fail in ways that do not mention it.
if (-not $env:VSINSTALLDIR) {
    Die @"
the Visual Studio environment is not initialised in this terminal.

  Open a terminal with ($Arch; adjust the edition/path for your install):

    $VcvarsHint

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

# The check behind "Neither Qt6 nor Qt5 is found".
#
# cmake says that when find_package cannot see Qt, and it names the symptom
# rather than the cause: Telegram Desktop links a STATIC Qt that prepare\win.bat
# installs under Libraries\win64\Qt-<version> (x64 and arm64) or
# Libraries\Qt-<version> (x86), so the message means that install is absent or
# half-written. Absent is the common case -- prepare's Qt stage starts by
# deleting the directory it installs into, so a run interrupted by a full disk or
# a dropped network leaves no Qt at all, and the stage's cache key (written only
# on success) is never written. Identified by what the build needs, a Qt6 cmake
# config, not by the version in the directory name.
#
# The architecture is part of the check, because upstream's cmake reads only the
# root for the architecture being built and prepare.py installs into the same one.
function Assert-PreparedQt {
    $qt = Find-PreparedQt (Get-PreparedQtRoot)
    if ($qt) {
        Log "prepared Qt: $qt"
        return
    }
    # The other root, for the architectures that do not share this one: x64 lives
    # in Libraries\win64 while x86 and arm64 live in Libraries, so Qt found in the
    # other place is a real answer ("prepared, but not for this architecture")
    # rather than a missing install.
    $otherRoot = Join-Path $Root 'desktop\Libraries'
    if ($Arch -eq 'x64') { $otherRoot = Join-Path $Root 'desktop\Libraries\win64' }
    $elsewhere = Find-PreparedQt $otherRoot
    if ($elsewhere) {
        Die @"
Qt is prepared, but for a different architecture:
      found     $elsewhere
      wanted    $(Get-PreparedQtRoot)
      cmake reads only the root for the architecture being built, so this looks
      exactly like "Neither Qt6 nor Qt5 is found". Prepare for this one:
        powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage prepare -Arch $Arch
"@
    }
    Die @"
the static Qt the app links against is not installed.
      cmake reports this as "Neither Qt6 nor Qt5 is found".
      prepare\win.bat installs Qt under $(Get-PreparedQtRoot)\Qt-<version>, and
      that directory is missing or half-written -- usually because prepare was
      interrupted. Run:
        powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage prepare -Arch $Arch
      (~35GB free, hours; it is a separate build of Qt, FFmpeg and OpenSSL from
      the ones a macOS build made in the same tree.)
"@
}

function Invoke-Prepare {
    Log "preparing third-party libraries for $Arch (hours, tens of GB)"

    # x86 and arm64 share Libraries\ with a macOS build -- only x64 gets its own
    # root -- and every prepare stage starts by deleting its own directory there.
    # So a prepare for one of those architectures rebuilds the library trees the
    # macOS build used. The macOS *install* (Libraries\local) is not a stage
    # directory and survives, so an app already built for macOS keeps working; a
    # macOS rebuild re-fetches those libraries. Say so instead of letting it be
    # discovered later.
    if ($Arch -ne 'x64' -and (Find-PreparedQt (Join-Path $Root 'desktop\Libraries\local'))) {
        Warn "this architecture shares Libraries\ with the macOS build in this tree:"
        Warn '  prepare deletes and rebuilds each library directory there, so the macOS'
        Warn '  library stages will have to be redone (its installed Qt in Libraries\local'
        Warn '  is untouched). Use a separate clone of this repository for both.'
    }

    Push-Location $Up
    try { & cmd /c 'Telegram\build\prepare\win.bat'; if ($LASTEXITCODE -ne 0) { Die 'prepare\win.bat failed' } }
    finally { Pop-Location }
}

function Invoke-Configure {
    Assert-PreparedQt

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
        # configure.bat takes the architecture as a bare first argument, in ITS
        # spelling ('arm' means ARM64 there, and x86 is its own default but also
        # accepted). NOT $args: that is a reserved automatic variable in
        # PowerShell, and assigning to it inside a function is a subtle way to get
        # surprised.
        $configureArgs = @(Get-ConfigureArch)
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
    Assert-PreparedQt
    # msbuild when it is available, so the build can run unattended; otherwise
    # say what to open rather than pretending to build.
    $msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuild) {
        Log "building with msbuild (Release, $(Get-MsbuildPlatform))"
        & msbuild $sln /p:Configuration=Release /p:Platform=$(Get-MsbuildPlatform) /m
        if ($LASTEXITCODE -ne 0) { Die 'msbuild failed' }
        Log "result under $Up\out\Release"
    } else {
        Warn "msbuild is not on PATH. Open $sln in Visual Studio 2026, select the"
        Warn 'Telegram project and Build > Build Telegram (Debug or Release).'
    }
}

# 'doctor' is not here: it runs and exits above the checks, before they can stop
# it, which is the whole point of a stage that reports what is missing.
switch ($Stage) {
    'prepare'   { Invoke-Prepare }
    'configure' { Invoke-Configure }
    'build'     { Invoke-Build }
    'all'       { Invoke-Prepare; Invoke-Configure; Invoke-Build }
}

Log 'done'
