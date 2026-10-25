<#
Build the FreeChat desktop client on Windows.

A wrapper around upstream's own flow, not a replacement for it. The authority is
desktop/upstream/docs/building-win.md; this script checks the prerequisites that
are easy to get wrong and then calls upstream's scripts.

NOT RUN END TO END. prepare/win.bat compiles Qt, FFmpeg, OpenSSL and ~30 more
libraries -- tens of GB and hours -- and no Windows machine was available while
this was written. What HAS been checked, against the pinned upstream sources
(Telegram/build/prepare/prepare.py, qt_version.py, cmake_helpers' run_cmake.py and
upstream's own .github/workflows/win.yml): the syntax under PowerShell 7, the
overlay applying to the pin, and every upstream fact this script relies on (which
Qt each architecture gets, where the libraries land, which solution file cmake
writes, which VS components upstream's CI installs). Treat a first failure as a
toolchain gap rather than a broken overlay.

The one thing that catches everyone: these commands must run in a terminal where
the Visual Studio environment has been initialised with the OLD toolset. VS
2026's default v145 does not support Windows 7, so upstream requires
-vcvars_ver=14.44. This script does that itself; by hand it is:

    %comspec% /k "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" -vcvars_ver=14.44

Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 [-Stage install|doctor|prepare|configure|build|all] [-Arch auto|x64|x86|arm64|both]

  -Stage install   installs what is missing through winget and Microsoft's own
                   Build Tools bootstrapper: Git, Python 3, and Visual Studio
                   Build Tools with the C++ workload, the 14.44 toolset, the
                   Windows SDK and CMake (plus ARM64 tools for -Arch arm64|both).
                   Nothing is reinstalled if it is already there.
#>
param(
    [ValidateSet('install', 'doctor', 'prepare', 'configure', 'build', 'all')]
    [string]$Stage = 'configure',
    [ValidateSet('auto', 'x64', 'x86', 'arm64', 'both')]
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

# Every step line carries the time. prepare runs for hours and a build for longer,
# and "which step was it in when it stopped" is the first question asked of a log
# somebody was not watching. Warnings carry it too, for the same reason.
function Log  { param($m) Say ("==> [$((Get-Date).ToString('HH:mm:ss'))] $m") }
function Warn { param($m) Say ("!   [$((Get-Date).ToString('HH:mm:ss'))] $m") }
function Die  {
    param($m)
    [Console]::Error.WriteLine("error: [$((Get-Date).ToString('HH:mm:ss'))] $m")
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
# both an Arm64 and an x64 view -- runs on Windows on Arm ONLY (Microsoft's
# "Arm64X PE files" documentation), so it does not replace an x64 build either. A
# Windows build is one architecture, and upstream ships one installer per
# architecture for the same reason (Telegram/build/setup.iss: tsetup-arm64.* with
# ArchitecturesAllowed="arm64", tsetup-x64.* with "x64compatible").
#
# What "universal" can mean here is therefore two builds, and two artifacts:
#
#   -Arch   $env:Platform   configure.bat   msbuild   libraries
#   x86     x86             x86             Win32     Libraries
#   x64     x64             x64             x64       Libraries\win64
#   arm64   arm64           arm           ARM64     Libraries
#   both    (two passes: x64 then arm64)
#
# `auto`, the default, reads the environment, and that is not laziness: prepare.py
# takes its architecture from exactly $env:Platform (set by the Visual Studio
# environment), so asking for x64 while the environment is ARM64 builds the
# libraries for one architecture and the app for the other, which fails while
# linking. When the environment does not match what was asked for, the script
# initialises it -- see Start-VsEnvironment below.
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

# What architecture the environment is set up for, if any. $env:Platform first,
# because that is the variable prepare.py reads, so agreeing with it is the only
# thing that matters.
function Get-EnvironmentArch {
    foreach ($candidate in @($env:Platform, $env:VSCMD_ARG_TGT_ARCH)) {
        if (-not $candidate) { continue }
        $value = $candidate.ToLower()
        if ($value -eq 'amd64') { $value = 'x64' }
        return $value
    }
    return ''
}

# Where Visual Studio is. vswhere is Microsoft's documented way to find it, and
# the fallback is the install paths of the editions this project's docs name.
#
# The ProgramFiles roots are read one by one because a missing environment
# variable is not an empty string for Join-Path -- it throws, and this runs in the
# doctor, whose job is to report what is missing rather than to die on it.
function Find-VsInstallPath {
    $roots = @()
    foreach ($name in @('ProgramFiles(x86)', 'ProgramFiles')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if ($value -and (Test-Path $value)) { $roots += $value }
    }
    # Every installation that has the C++ x64/x86 tools, not just the newest: a
    # machine with VS 2026 (no 14.44 toolset) next to VS 2022 (which has it) must
    # resolve to the one that can actually build, and -latest would pick the other.
    # Build Tools count -- they are what the install stage puts on a clean machine.
    $all = @()
    foreach ($root in $roots) {
        $vswhere = Join-Path $root 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $vswhere) {
            $lines = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
            foreach ($line in $lines) {
                if ($line -and (Test-Path $line.Trim())) { $all += $line.Trim() }
            }
        }
    }
    if ($all.Count -eq 0) {
        foreach ($root in $roots) {
            foreach ($candidate in @('18\Community', '18\Professional', '18\Enterprise', '18\BuildTools',
                                     '2022\Community', '2022\Professional', '2022\Enterprise', '2022\BuildTools')) {
                $path = Join-Path $root "Microsoft Visual Studio\$candidate"
                if (Test-Path $path) { $all += $path }
            }
        }
    }
    foreach ($path in $all) {
        if (Test-VsToolset144 $path) { return $path }
    }
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}

# Is the 14.44 toolset (v143 line, the last one that targets Windows 7) installed
# in this Visual Studio? vcvarsall.bat -vcvars_ver=14.44 fails without it, and the
# failure is a line in a wall of output.
function Test-VsToolset144 {
    param([string]$VsPath)
    if (-not $VsPath) { return $false }
    $found = Get-ChildItem -Path (Join-Path $VsPath 'VC\Tools\MSVC') -Directory -Filter '14.44*' -ErrorAction SilentlyContinue
    return [bool]$found
}

# The Windows SDK upstream builds with (docs/building-win.md: "10.0.26100.0 SDK
# version"; its CI passes the same number to the environment setup). Returns the
# version when that SDK is installed, else nothing -- the caller then lets
# vcvarsall take its default, which is the newest installed.
function Find-WantedSdk {
    $want = '10.0.26100.0'
    foreach ($name in @('ProgramFiles(x86)', 'ProgramFiles')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if ($value -and (Test-Path (Join-Path $value "Windows Kits\10\Include\$want"))) { return $want }
    }
    return $null
}

# Does the Visual Studio at $VsPath have the MSVC ARM64 tools? Not in the default
# C++ workload, and vcvarsall.bat arm64 fails without them.
function Test-VsArm64Tools {
    param([string]$VsPath)
    if (-not $VsPath) { return $false }
    foreach ($dir in @(Get-ChildItem -Path (Join-Path $VsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $dir.FullName 'bin\Hostx64\arm64\cl.exe')) { return $true }
        if (Test-Path (Join-Path $dir.FullName 'bin\Hostarm64\arm64\cl.exe')) { return $true }
    }
    return $false
}

# The solution cmake wrote. Visual Studio 2026 generates Telegram.slnx and Visual
# Studio 2022 Telegram.sln (upstream's docs name .slnx, its older scripts .sln),
# and which one it is depends on the VS that cmake picked -- so look for either
# rather than naming one and calling a good configure "not configured yet".
function Find-Solution {
    foreach ($name in @('Telegram.slnx', 'Telegram.sln')) {
        $candidate = Join-Path $Up "out\$name"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# Where the per-architecture artifacts are kept. `out\` is shared between
# architectures -- configure discards it when the stamp changes, and the stamp
# changes when the architecture does -- so a second pass would delete the first
# pass's EXE. One payload per architecture is also exactly what the installer
# wants (Telegram/build/setup.iss takes one folder per build target).
function Get-DistPath { return (Join-Path $Root 'desktop\dist') }

function Copy-BuiltApp {
    param([string]$WhichArch)
    $release = Join-Path $Up 'out\Release'
    $exe = $null
    foreach ($name in @('FreeChat.exe', 'Telegram.exe')) {
        $candidate = Join-Path $release $name
        if (Test-Path $candidate) { $exe = $candidate; break }
    }
    if (-not $exe) {
        Warn "the $WhichArch build left no EXE under $release - nothing to keep"
        return
    }
    $dist = Get-DistPath
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $target = Join-Path $dist ([System.IO.Path]::GetFileNameWithoutExtension($exe) + "-$WhichArch.exe")
    Copy-Item -Force $exe $target
    Log "kept the $WhichArch build: $target"
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

# Python block-buffers its stdout whenever it is not a terminal, and every child
# process here is one. prepare.py narrates what it is about to do -- the stage it
# is on, and the commands it is about to run -- and buffered, all of that arrives
# in a lump AFTER the half hour it describes. Unbuffered, it arrives where it
# happened, which is the difference between a log that says what is going on and
# one that says what went on.
$env:PYTHONUNBUFFERED = '1'

# Printed before any check runs, so that "the script did nothing" can never mean
# "the script said nothing": the first line is on screen whatever happens next.
Log "FreeChat desktop - windows, $Arch ($ArchOrigin), stage $Stage"
Say "    root $Root"

# --- helpers the checks and the doctor both need ---------------------------
#
# Defined before the checks below, because -Stage doctor runs before them: its
# whole point is to report a missing prerequisite instead of dying on it, so it
# cannot be behind the checks that die.

# One line per submodule that is not fully checked out, from git itself. Also sets
# $SubmoduleCount to how many it saw, from the same call: on a shared folder each
# `git submodule status --recursive` costs, and asking twice for one answer is a
# minute of nothing happening on screen.
$SubmoduleCount = 0
function Get-SubmoduleProblems {
    $script:SubmoduleCount = 0
    $bad = @()
    # No git is its own report ("git ... not on PATH"); asking it anything here
    # would be a command-not-found from inside a diagnostic.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $bad }
    foreach ($line in (& git -C $Up submodule status --recursive 2>$null)) {
        if (-not $line) { continue }
        $script:SubmoduleCount++
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

# The Qt install under a libraries root, found by what the build needs -- a Qt
# cmake config -- and not by the version in the directory name, which follows
# upstream's qt_version.py.
#
# Qt5 OR Qt6, and that is not tolerance for its own sake: qt_version.py gives x86
# and x64 Qt 5.15.x and only arm64 (or an explicit `qt6` argument) Qt 6, so on
# the default architecture a COMPLETE prepare leaves lib\cmake\Qt5\Qt5Config.cmake
# and no Qt6 file at all. Looking only for Qt6 reported a finished x64 prepare as
# "missing or half-written", and the configure stage refused to start.
function Find-PreparedQt {
    param([string]$LibrariesRoot)
    $found = Get-ChildItem -Path (Join-Path $LibrariesRoot 'Qt-*') -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'lib\cmake\Qt5\Qt5Config.cmake')) -or
            (Test-Path (Join-Path $_.FullName 'lib\cmake\Qt6\Qt6Config.cmake'))
        }
    if ($found) { return @($found)[0].FullName }
    return $null
}

# Is this a working Python 3? Asked of the interpreter rather than inferred from
# its name: a `python` that is Python 2 is worse than no python, because it runs
# and then fails inside a script.
#
# The failure contained here is real and was found on the first Windows run:
# `python` can be the Microsoft Store alias in
# %LOCALAPPDATA%\Microsoft\WindowsApps -- a shim that prints an advertisement to
# stderr and exits non-zero. `& $exe @probe 2>$null` under
# $ErrorActionPreference = 'Stop' turned that into a TERMINATING error whose
# message was the shim's text, so the script died while merely looking for a
# tool it did not have. Native commands are therefore run with the preference
# relaxed and their streams merged, and every failure means "no", nothing else.
function Test-Python3 {
    param([string[]]$Command)
    if ($Command.Count -eq 0) { return $false }
    $exe = $Command[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $false }
    $probe = @()
    if ($Command.Count -gt 1) { $probe += $Command[1..($Command.Count - 1)] }
    $probe += @('-c', 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)')
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ok = $false
    try {
        & $exe @probe 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    } catch {
        $ok = $false
    } finally {
        $ErrorActionPreference = $saved
    }
    return $ok
}

# A working Python 3 under the name `python`, or nothing.
#
# That exact name, because upstream's own Telegram\build\prepare\win.bat and
# Telegram\configure.bat run `python <script>.py` and nothing else. A machine where
# only `py -3` works (python.org installs the py launcher, and the Microsoft Store
# alias shadows `python` in PATH) passed the old check and then failed inside
# win.bat with the alias's advertisement. So when `python` itself is unusable but
# the launcher finds a real interpreter, that interpreter's directory goes in front
# of PATH for this process -- and so for every child, win.bat included.
function Get-PythonCommand {
    if (Test-Python3 @('python')) { return 'python' }
    if (Test-Python3 @('py', '-3')) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $exe = $null
        try { $exe = & py -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1 } catch { }
        $ErrorActionPreference = $saved
        if ($exe -and (Test-Path $exe)) {
            $dir = Split-Path -Parent $exe
            $env:Path = "$dir;$dir\Scripts;$env:Path"
            if (Test-Python3 @('python')) { return "python (via py -3: $exe)" }
        }
    }
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
    param([switch]$NoExit)
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

    # Which processor this actually is. It decides which prompt to open, and with
    # -Arch auto the two are meant to match; when they do not, that is the whole
    # reason to say so here.
    $cpu = $env:PROCESSOR_ARCHITECTURE
    if (-not $cpu) {
        # Not set under PowerShell on other systems; the fallback keeps this from
        # being a blank line in a report.
        try { $cpu = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $cpu = 'unknown' }
    }
    if ($env:PROCESSOR_ARCHITEW6432) { $cpu = "$cpu (32-bit shell on $env:PROCESSOR_ARCHITEW6432)" }
    Report 'processor' $cpu
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -and $Arch -ne 'arm64') {
        Say  '                    ARM64 machine; this build is for another architecture.'
        Say  '                    For arm64: -Arch arm64. For both payloads: -Arch both.'
    }

    try {
        $drive = Get-Item $Root
        $driveName = $drive.PSDrive.Name
        $freeGb = [math]::Round((Get-PSDrive $driveName).Free / 1GB)
        Report 'disk free' "${freeGb}GB on $($driveName):"
        # A mapped drive is usually a VM's shared folder (\\Mac\Home,
        # \\vmware-host) or a network share, and two things go wrong there without
        # saying why: git over a share is slow and locks files, and the build wants
        # hardlinks and symlinks that SMB does not have -- Qt's syncqt and the
        # library stages both use them.
        $driveType = 'unknown'
        # Only a drive letter names a DriveInfo; this script is also run on other
        # systems in tests, where the name is a path.
        if ($driveName -match '^[A-Za-z]$') {
            try {
                $driveType = ([System.IO.DriveInfo]::new("$($driveName):")).DriveType.ToString().ToLower()
            } catch { }
        }
        Report 'drive' "$($driveName): - $driveType"
        if ($driveType -eq 'network') {
            Say  '                    a mapped or network drive (a VM shared folder reports the'
            Say  '                    same). git and a multi-hour build are slow and fragile'
            Say  '                    there, and hardlinks and symlinks that Qt and the library'
            Say  '                    stages need do not work over SMB. A path inside the machine,'
            Say  '                    C:\dev\ for example, avoids all of it.'
        }
    } catch {
        Report 'disk free' 'unknown'
    }

    # The one prerequisite that is not on PATH, and the reason prepare\win.bat
    # and configure.bat fail without mentioning it. NOT blocking when Visual Studio
    # is installed: the script initialises the environment for the architecture
    # itself (the Visual Studio section below), so a plain terminal is enough.
    $vsPath = Find-VsInstallPath
    if ($env:VSINSTALLDIR) {
        Report 'visual studio' "initialised ($env:VSINSTALLDIR)"
    } elseif ($vsPath) {
        Report 'visual studio' "found at $vsPath"
        Say  "                    the script initialises it for $Arch when a stage runs"
    } else {
        Report 'visual studio' 'NOT found - install "Desktop development with C++"' -Blocking
        Say  '                    vswhere.exe and the usual install paths were both checked'
        Say  '                    -Stage install does it'
        $blockers++
    }
    if ($vsPath) {
        if (Test-VsToolset144 $vsPath) {
            Report 'toolset 14.44' 'present'
        } else {
            Report 'toolset 14.44' 'MISSING - vcvarsall -vcvars_ver=14.44 will fail' -Blocking
            Say  '                    add "MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.44-17.14)"'
            Say  '                    in the Visual Studio Installer, or run -Stage install'
            $blockers++
        }
        if (Find-WantedSdk) {
            Report 'windows sdk' '10.0.26100.0 (the one upstream builds with)'
        } else {
            Report 'windows sdk' '10.0.26100.0 not found - the newest installed one will be used'
        }
        if ($Arch -eq 'arm64' -or $RequestedArch -eq 'both') {
            if (Test-VsArm64Tools $vsPath) {
                Report 'arm64 tools' 'present'
            } else {
                Report 'arm64 tools' 'MISSING - "MSVC ARM64 build tools" is not in the default workload' -Blocking
                Say  '                    -Stage install -Arch arm64 adds it'
                $blockers++
            }
        }
    }

    # Long paths. Qt's own build tree nests deeper than the 260-character limit
    # allows from a long checkout path, and the failure is a file that "does not
    # exist" in the middle of a multi-hour stage. Upstream builds from D:\TBuild
    # for this reason.
    $longPaths = $null
    try { $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled } catch { }
    if ($longPaths -eq 1) {
        Report 'long paths' 'enabled'
    } else {
        Report 'long paths' 'not enabled (or unreadable) - keep the checkout path short'
    }
    if ($Root.Length -gt 40) {
        Report 'path length' "$($Root.Length) characters: $Root"
        Say  '                    long for a tree this deep. C:\fc or D:\TBuild is safer.'
    }

    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) {
        Report 'git' "$($cmd.Source)"
    } else {
        Report 'git' 'not on PATH - install Git for Windows' -Blocking
        $blockers++
    }

    # bash is needed for the bootstrap and overlay steps of the README -- which
    # the reports above have already shown are done in this tree. prepare,
    # configure and build do not use it: prepare drives cmd/bat and carries its
    # own msys under ThirdParty. So this is reported, not required.
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) {
        Report 'bash' "$($cmd.Source)"
    } else {
        Report 'bash' 'not on PATH - only the bootstrap/overlay steps need it'
        Say  '                    to run those: add C:\Program Files\Git\bin to PATH, or use'
        Say  '                    the Git Bash shortcut'
    }

    $python = Get-PythonCommand
    if ($python) {
        Report 'python 3' $python
    } else {
        Report 'python 3' 'not found - prepare and configure need it' -Blocking
        if (Get-Command python -ErrorAction SilentlyContinue) {
            Say  '                    a `python` exists but is not Python 3, which is usually the'
            Say  '                    Microsoft Store alias: turn it off under Settings > Apps >'
            Say  '                    Advanced app settings > App execution aliases, or install'
            Say  '                    Python 3 from python.org and tick "Add to PATH".'
        } else {
            Say  '                    install Python 3 from python.org and tick "Add to PATH"'
            Say  '                    (`python3` does not exist on Windows; `python` and `py -3` do).'
        }
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
    if ($Arch -eq 'arm64') {
        Say  '                    (arm64 gets Qt 6; x86 and x64 get Qt 5.15 - upstream qt_version.py)'
    }

    # The one hazard of sharing a tree with a macOS build: x86 and arm64 use the
    # same Libraries\ root that the macOS stages build in, and each stage starts by
    # deleting its own directory. Reported here because it is a fact about the
    # tree, not a failure -- the macOS build already produced stays usable.
    if ($Arch -ne 'x64' -and (Find-PreparedQt (Join-Path $Root 'desktop\Libraries\local'))) {
        Report 'macOS libraries' 'present in Libraries\ - a prepare here rebuilds them for Windows'
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Report 'submodules' 'cannot check - git is not on PATH'
    } elseif (Test-Path (Join-Path $Up '.git')) {
        $subs = Get-SubmoduleProblems
        if ($subs.Count -eq 0) {
            Report 'submodules' "$SubmoduleCount complete"
        } else {
            Report 'submodules' "$($subs.Count) problem(s):" -Blocking
            foreach ($s in $subs) { Say "                    $s" }
            $blockers++
        }
    } else {
        Report 'submodules' 'cannot check - no upstream checkout'
    }

    $sln = Find-Solution
    if ($sln) {
        Report 'build output' "configured ($sln)"
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
        if (-not $NoExit) { exit 1 }
        return
    }
    Say '  nothing blocking. next: -Stage all'
}

# --- installing what is missing ----------------------------------------------
#
# winget for Git and Python, Microsoft's own bootstrapper for Visual Studio Build
# Tools -- the same https://aka.ms/vs/18/stable/vs_buildtools.exe and the same
# component names upstream's CI uses to get the ARM64 tools
# (.github/workflows/win.yml, "Install VS 2026 Build Tools."). Only what is
# missing is installed: an existing Git, a working Python 3 or a Visual Studio
# that already has everything is left alone.
#
# This is the one stage that changes the machine, so it says each thing before it
# does it, and it never touches an existing Visual Studio -- Build Tools install
# beside it, and Find-VsInstallPath picks whichever has the 14.44 toolset.

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# A freshly installed tool is on the machine's PATH but not on this process's:
# the environment was copied before the installer ran. Re-read it, so the checks
# after an install see what the install did instead of reporting it missing.
function Update-SessionPath {
    $parts = @()
    foreach ($scope in @('Machine', 'User')) {
        $value = [System.Environment]::GetEnvironmentVariable('Path', $scope)
        if ($value) { $parts += $value }
    }
    if ($parts.Count -gt 0) { $env:Path = ($parts -join ';') }
}

function Install-WithWinget {
    param([string]$Id, [string]$Label)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die @"
winget is not available, and the install stage uses it for Git and Python.
  It comes with "App Installer" from the Microsoft Store (Windows 10 1809+ / 11).
  Or install these by hand and skip this stage:
    Git        https://git-scm.com/download/win
    Python 3   https://www.python.org/downloads/  (tick "Add python.exe to PATH")
    Visual Studio 2026 Build Tools, "Desktop development with C++", plus the
    14.44 toolset and the Windows 11 SDK 26100
"@
    }

    Log "installing $Label ($Id) with winget"
    Say "    `$ winget install --id $Id --exact --silent"
    & winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    $code = $LASTEXITCODE
    # -1978335189 is winget's "already installed, nothing to upgrade".
    if ($code -ne 0 -and $code -ne -1978335189) {
        Die "winget could not install $Label (exit $code). Install it by hand and run this again."
    }
    Update-SessionPath
}

function Install-VisualStudioBuildTools {
    param([bool]$WithArm64)
    $url = 'https://aka.ms/vs/18/stable/vs_buildtools.exe'
    $exe = Join-Path ([System.IO.Path]::GetTempPath()) 'vs_buildtools.exe'
    Log 'downloading the Visual Studio Build Tools installer'
    Say "    `$ $url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    } catch {
        Die "could not download $url : $($_.Exception.Message)"
    }

    # What the build needs, by Microsoft's component ids:
    #   Workload.VCTools                       the C++ build tools
    #   VC.14.44.17.14.x86.x64                 the toolset -vcvars_ver=14.44 selects
    #   Windows11SDK.26100                     upstream's SDK (building-win.md)
    #   VC.CMake.Project                       the cmake and ninja that vcvars puts on PATH
    #   VC.ATL                                 ATL, which the app and its libraries use
    $components = @(
        'Microsoft.VisualStudio.Workload.VCTools',
        'Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64',
        'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        'Microsoft.VisualStudio.Component.VC.CMake.Project',
        'Microsoft.VisualStudio.Component.VC.ATL'
    )
    if ($WithArm64) {
        $components += @(
            'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
            'Microsoft.VisualStudio.Component.VC.14.44.17.14.ARM64',
            'Microsoft.VisualStudio.Component.VC.ATL.ARM64'
        )
    }
    $installerArgs = @('--quiet', '--wait', '--norestart', '--nocache')
    foreach ($c in $components) { $installerArgs += @('--add', $c) }

    Log 'installing Visual Studio Build Tools (several GB; a few minutes to half an hour)'
    Say "    `$ vs_buildtools.exe $($installerArgs -join ' ')"
    $process = $null
    if (Test-IsAdmin) {
        $process = Start-Process -FilePath $exe -ArgumentList $installerArgs -Wait -PassThru
    } else {
        Say '    asking for administrator rights (a UAC prompt will appear)'
        try {
            $process = Start-Process -FilePath $exe -ArgumentList $installerArgs -Wait -PassThru -Verb RunAs
        } catch {
            Die "the Visual Studio installer needs administrator rights and did not get them: $($_.Exception.Message)"
        }
    }
    Remove-Item -Force $exe -ErrorAction SilentlyContinue
    # 3010 is "success, a reboot is needed".
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        Die "the Visual Studio installer failed (exit $($process.ExitCode)). Its log is under $env:TEMP (dd_*.log)."
    }
    if ($process.ExitCode -eq 3010) { Warn 'Visual Studio asks for a reboot before the build.' }
}

function Invoke-Install {
    Log 'checking what is missing'
    $needArm64 = ($Arch -eq 'arm64' -or $RequestedArch -eq 'both')

    try {
        $drive = (Get-Item $Root).PSDrive
        $freeGb = [math]::Round($drive.Free / 1GB)
        if ($freeGb -lt 80) {
            Warn "only ${freeGb}GB free on $($drive.Name): - the tools take ~10GB and prepare ~35GB more (60GB+ in all)"
        }
    } catch { }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Say '    git: present'
    } else {
        Install-WithWinget 'Git.Git' 'Git for Windows'
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        # Qt's source tree nests deeper than 260 characters; per-user, harmless.
        & git config --global core.longpaths true
    }

    $python = Get-PythonCommand
    if ($python) {
        Say "    python 3: $python"
    } else {
        # 3.12: the interpreter upstream's own CI runners carry. Overridable for a
        # machine that needs another.
        $pythonId = $env:FREECHAT_PYTHON_WINGET_ID
        if (-not $pythonId) { $pythonId = 'Python.Python.3.12' }
        Install-WithWinget $pythonId 'Python 3'
        if (-not (Get-PythonCommand)) {
            Warn 'Python is installed but `python` still does not resolve to it.'
            Warn '  Turn off the Microsoft Store alias: Settings > Apps > Advanced app settings >'
            Warn '  App execution aliases (python.exe and python3.exe), then open a new terminal.'
        }
    }

    $vs = Find-VsInstallPath
    $haveToolset = Test-VsToolset144 $vs
    $haveArm64 = Test-VsArm64Tools $vs
    if ($vs -and $haveToolset -and (-not $needArm64 -or $haveArm64)) {
        Say "    visual studio: $vs (14.44 toolset present)"
    } else {
        if ($vs) { Say "    visual studio: $vs - but missing components, adding Build Tools beside it" }
        Install-VisualStudioBuildTools $needArm64
    }

    Update-SessionPath
    Say ''
    Log 'install finished - checking the result'
    Say '    (a terminal opened BEFORE the install does not see the new PATH; open a new one if the check below disagrees)'
    Invoke-Doctor -NoExit
    Say ''
    Say '  Anything still listed above that is not a tool (the upstream tree, the overlay,'
    Say '  the prepared Qt, the submodules) is a step of the build itself, not of this stage:'
    Say '  bootstrap.sh and apply-overlay.sh from Git Bash, then -Stage all.'
}

# Install is dispatched before the per-architecture passes below: it runs once, and
# for -Arch both it installs the tools of both architectures in that one run.
# It exists for the machine that cannot pass the checks further down yet.
if ($Stage -eq 'install') {
    Invoke-Install
    exit 0
}

# --- both architectures -----------------------------------------------------
#
# Two passes, each in its own process, because the Visual Studio environment is
# per-architecture and a child cannot change its parent's. Each child initialises
# its own environment, so this works from any terminal, and each child's artifact
# is copied out before the next pass discards out\ (the configure stamp includes
# the architecture). The result is the two payloads an installer needs.
if ($RequestedArch -eq 'both') {
    Log "both: x64 and arm64, one after the other ($Stage each)"
    if (-not $env:VSINSTALLDIR) {
        Say '    each pass initialises the Visual Studio environment for its own architecture'
    }
    $failed = @()
    foreach ($one in @('x64', 'arm64')) {
        Log "both: $one, stage $Stage"
        # Contained: a child that cannot even start (no cmd, a policy blocking
        # PowerShell) is a failed pass with a name, not the end of the run -- the
        # point of this pass is to report on both architectures.
        $code = 1
        try {
            & cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stage $Stage -Arch $one"
            $code = $LASTEXITCODE
        } catch {
            Say "    could not start the $one pass: $($_.Exception.Message)"
        }
        if ($code -ne 0) {
            Warn "both: the $one pass failed (exit $code)"
            $failed += $one
        } elseif ($Stage -eq 'build' -or $Stage -eq 'all') {
            Copy-BuiltApp $one
        }
    }
    if ($failed.Count -gt 0) {
        Die ("both: these passes failed: " + ($failed -join ', '))
    }
    if ($Stage -eq 'build' -or $Stage -eq 'all') {
        Log "both: artifacts under $(Get-DistPath)"
    }
    exit 0
}

# Doctor runs before the checks that die, by design: its job is to report what is
# missing, including the things the checks below treat as fatal.
if ($Stage -eq 'doctor') {
    Invoke-Doctor
    exit 0
}

# --- the Visual Studio environment ------------------------------------------
#
# cl.exe, msbuild and the right toolset come from it, and it is PER ARCHITECTURE:
# an x64 terminal cannot build arm64. Upstream's answer is to open the right
# prompt by hand (building-win.md), which is one more thing to get wrong before a
# build measured in hours -- and on Windows on Arm the ARM64 prompt is not the one
# a shortcut gives you.
#
# So the environment is initialised here when it does not match the architecture
# being built, and this script re-enters itself inside it: a child cmd.exe cannot
# change its parent's environment, so the work has to happen in a process that
# vcvarsall started. FREECHAT_VS_READY marks that second entry, so a vcvarsall
# that fails to set what we expect cannot loop.
$VsReadyVar = 'FREECHAT_VS_READY'
$EnvArch = Get-EnvironmentArch
if ($EnvArch -ne $Arch) {
    if (Test-Path "env:$VsReadyVar") {
        Warn "the Visual Studio environment still does not report $Arch (it says '$EnvArch')."
        Warn '  Continuing, but prepare.py reads the same variable and may refuse.'
    } else {
        $vs = Find-VsInstallPath
        if (-not $vs) {
            Die @"
Visual Studio was not found, and it is required to build.

  Looked for vswhere.exe under ${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer,
  and for Visual Studio 18/2022 under $env:ProgramFiles.
  Install "Desktop development with C++" from the Visual Studio installer: that is
  what provides cl.exe, msbuild and vcvarsall.bat.
"@
        }
        $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
        if (-not (Test-Path $vcvars)) {
            Die "vcvarsall.bat is missing under $vs - the C++ workload is not installed."
        }
        # The SDK upstream builds with, when it is installed (see Find-WantedSdk).
        $sdk = Find-WantedSdk
        $sdkArg = ''
        if ($sdk) { $sdkArg = "$sdk " }
        if (-not (Test-VsToolset144 $vs)) {
            Warn "the 14.44 toolset is not installed in ${vs}: vcvarsall -vcvars_ver=14.44 will fail."
            Warn '  powershell -File scripts\build-desktop.ps1 -Stage install   adds it.'
        }
        Log "visual studio: initialising the $Arch environment"
        Say "    $ `"$vcvars`" $Arch $sdkArg-vcvars_ver=14.44"
        # A batch file, not one long `cmd /c "a && set X=1 && b"` line. In cmd,
        # `set Platform=x64 && next` stores "x64 " WITH the space before the &&,
        # so Platform came out as "x64 " -- which is not 'x64' to prepare.py
        # (os.environ['Platform'] == 'x64'), and the very next stage refused to
        # start with "Make sure to run from Native Tools Command Prompt". The
        # quoted `set "X=Y"` form has no such trailing space, and a file also
        # leaves nothing for cmd's quote-stripping rules to get wrong.
        #
        # Platform is set AFTER vcvarsall, so that prepare.py reads the value this
        # environment actually is, whether or not vcvarsall sets it itself.
        $batLines = @(
            '@echo off',
            "call `"$vcvars`" $Arch $sdkArg-vcvars_ver=14.44",
            'if errorlevel 1 exit /b %errorlevel%',
            "set `"Platform=$Arch`"",
            "set `"$VsReadyVar=1`"",
            "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stage $Stage -Arch $Arch",
            'exit /b %errorlevel%'
        )
        $bat = Join-Path ([System.IO.Path]::GetTempPath()) "freechat-vs-$PID.cmd"
        [System.IO.File]::WriteAllText($bat, (($batLines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
        try {
            & cmd /c "`"$bat`""
            $code = $LASTEXITCODE
        } finally {
            Remove-Item -Force $bat -ErrorAction SilentlyContinue
        }
        if ($code -ne 0) {
            Warn "the Visual Studio environment could not be initialised for $Arch (exit $code)."
            if ($Arch -eq 'arm64') {
                Warn '  For arm64 the "MSVC ARM64 build tools" component must be installed;'
                Warn '  it is not part of the default C++ workload.'
            }
            Warn '  Or open the right prompt by hand and run this again from there:'
            Warn "    $VcvarsHint"
        }
        exit $code
    }
}

# An environment opened by hand (or inherited) can be the right architecture and the
# wrong toolset: VS 2026's default v145 cannot target Windows 7, which upstream
# still supports, and the failure appears hours into prepare. VCToolsVersion is
# what vcvars sets, so it says which one this really is.
if ($env:VCToolsVersion -and -not $env:VCToolsVersion.StartsWith('14.44')) {
    Warn "the Visual Studio environment uses toolset $($env:VCToolsVersion), not 14.44."
    Warn '  Upstream requires -vcvars_ver=14.44; open a new terminal and let this script'
    Warn '  initialise it, or see the hint at the top of the file.'
}

# --- the phases that used to be silent --------------------------------------
#
# A run that stops must not look like a run that did nothing: on a mapped drive
# (a VM's shared folder) the git scans alone take minutes, and the first report of
# this script was "it printed two lines and stopped" -- which was a check that had
# not finished yet and a later check that would have refused anyway. Each phase
# now says what it is about to do, and the cheap machine prerequisites come before
# the expensive tree scan, so the answer that matters arrives first.

Log 'checking the tree and the overlay'
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

Log 'checking the toolchain'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is not on PATH. Install Git for Windows (https://git-scm.com/download/win)."
}

# The VS environment is what makes cl.exe and the right toolset available. Without
# it prepare/win.bat and configure.bat fail in ways that do not mention it. Checked
# before the submodules, because it costs nothing and it is the one prerequisite
# that is not on PATH -- waiting minutes for a tree scan to be told about an
# environment variable is the wrong order.
if (-not $env:VSINSTALLDIR) {
    Die @"
the Visual Studio environment is not initialised, and the script's own attempt to
set it up did not take (see the messages above it).

  Open a terminal with ($Arch; adjust the edition/path for your install) and run
  this stage from there:

    $VcvarsHint

  -vcvars_ver=14.44 is required: VS 2026's default v145 toolset does not support
  Windows 7, which Telegram Desktop still targets. See
  desktop/upstream/docs/building-win.md.
"@
}

# Git Bash, needed for the bootstrap and overlay steps -- and only for them. This
# used to be fatal, which is wrong twice over: the checks above have already
# established that this tree is bootstrapped and overlaid (so those steps are
# done), and prepare, configure and build never call bash at all: prepare drives
# cmd/bat and carries its own msys under ThirdParty. A machine that can build was
# being refused because it could not run a step it did not need.
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Warn 'bash is not on PATH.'
    Warn '  The bootstrap and overlay steps in the README run under it, so add it if you'
    Warn '  still have to run them:'
    Warn '    add C:\Program Files\Git\bin to PATH, or use the "Git Bash" shortcut.'
    Warn '  Do NOT use WSL for that: a WSL checkout cannot see your Visual Studio'
    Warn '  installation, and the build needs MSVC on the Windows side.'
    Warn '  prepare, configure and build themselves do not need bash.'
}

# Python 3 under any of its Windows names. A python.org install provides
# python.exe and the py.exe launcher and NOT python3, and this check has to accept
# the same set the rest of the toolchain does or it rejects a machine that works.
$python = Get-PythonCommand
if (-not $python) {
    Die @"
no working Python 3 found (tried python3, python, py -3).

  Install Python 3 from python.org and tick "Add python.exe to PATH" in the
  installer. Upstream's own build scripts expect Python 3.10 or newer on PATH.

  If a `python` does exist but is not Python 3, it is usually the Microsoft Store
  alias: turn it off under Settings > Apps > Advanced app settings > App
  execution aliases.
"@
}
Log "python 3: $python"

Log 'reading the configuration'

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

# --- the submodules, last of the checks --------------------------------------
#
# Last because it is the expensive one: `git submodule status --recursive` is one
# git invocation per submodule, and on a mapped drive (a VM's shared folder) the
# desktop client's 40 of them take minutes. That is what the first report of this
# script looked like from the outside -- "it prints two lines and stops" -- so the
# phase announces itself, and by the time it runs, the cheap prerequisites have
# already had their say.
Log 'verifying the submodules (one git call each; slow on a shared folder)'

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
    if ($bad.Count -eq 0) {
        Log "submodules: $SubmoduleCount checked out and complete"
        return
    }
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
    Log "submodules: $SubmoduleCount checked out and complete after the repair"
}

Assert-Submodules

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

    # The command, before it runs: a log is kept so that "which command, exactly"
    # has an answer.
    #
    # `silent` is upstream's own flag for an unattended run (its CI passes it): a
    # stage whose recipe changed since it was built is rebuilt, where without it
    # prepare.py stops and waits for a keypress ("(r)ebuild, (s)kip, (q)uit?") --
    # forever, in a run nobody is watching. A fresh tree never reaches that
    # prompt, but a resumed or updated one does.
    Say '    $ Telegram\build\prepare\win.bat silent'
    Push-Location $Up
    try { & cmd /c 'Telegram\build\prepare\win.bat silent'; if ($LASTEXITCODE -ne 0) { Die 'prepare\win.bat failed' } }
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
    # The API hash is elided in the echoed line: it comes from freechat.env and is
    # not a secret (gramsrv does not validate it), but a log gets pasted into bug
    # reports and there is no reason to copy it there.
    Say "    $ configure.bat $(Get-ConfigureArch) -D TDESKTOP_API_ID=$apiId -D TDESKTOP_API_HASH=<hash>"
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
    $sln = Find-Solution
    if (-not $sln) { Die "not configured yet - run this script with -Stage configure" }
    Assert-PreparedQt
    # msbuild when it is available, so the build can run unattended; otherwise
    # say what to open rather than pretending to build.
    $msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuild) {
        Log "building with msbuild (Release, $(Get-MsbuildPlatform))"
        # /t:Telegram is "Build Telegram" from upstream's instructions: the app and
        # what it depends on. The whole solution would also build the Updater,
        # the Packer and cmake's ALL_BUILD for nothing a run of the client needs.
        Say "    $ msbuild $sln /t:Telegram /p:Configuration=Release /p:Platform=$(Get-MsbuildPlatform) /m"
        & msbuild $sln /t:Telegram /p:Configuration=Release /p:Platform=$(Get-MsbuildPlatform) /m
        if ($LASTEXITCODE -ne 0) { Die 'msbuild failed' }
        Log "result under $Up\out\Release"
    } else {
        Warn "msbuild is not on PATH. Open $sln in Visual Studio, select the"
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
