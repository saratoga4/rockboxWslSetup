<#
.SYNOPSIS
    Sets up the Rockbox cross-compilers on Windows using WSL, then (optionally)
    does a test build to confirm they work.

.DESCRIPTION
    Automates the "Windows10CrossCompiler" guide from the Rockbox wiki:

      1. Installs WSL (Windows Subsystem for Linux) if it is missing. This needs
         administrator rights: when WSL is missing and the script is not running as
         administrator, it says so and stops. A restart may be needed; the script
         resumes automatically (as administrator) after you log back in.
      2. Installs Ubuntu and creates your Linux user account.
      3. Installs the Linux build dependencies (apt-get).
      4. Downloads (clones) the Rockbox source code.
      5. Builds the Rockbox cross-compiler(s) you choose with tools/rockboxdev.sh.
      6. Optionally does a test build of Rockbox with each compiler, to confirm the
         tools work, and copies the resulting rockbox-<player>.zip to Windows.
      7. Optionally builds the Rockbox simulator as a Windows program (rockboxui.exe).

    Without parameters the script asks: which compilers to install, whether to do a
    test build, and (for a new Ubuntu) a Linux user name and password.

    The script is safe to run again. Finished steps are skipped, so a second run
    only rebuilds Rockbox.

.PARAMETER Toolchains
    Which cross-compilers to build, without asking. Choices: arm (iPods, Sansas, most
    players), m68k, mips, arm-linux, mips-linux. Separate several with commas.

.PARAMETER Target
    Build Rockbox for these targets (players) instead of asking about a test build,
    for example ipodvideo or sansaclipplus,ipod6g. Use "none" to skip building.

.PARAMETER Simulator
    Also build the Rockbox simulator as a Windows .exe for the first target.

.PARAMETER ShowResults
    When done, open the output folder and start the simulator (if built). This is
    switched on automatically when you choose a test build.

.PARAMETER SimulatorArch
    32 (recommended by the Rockbox wiki) or 64.

.PARAMETER Distro
    Name of the WSL distribution to use or install. Default: Ubuntu.

.PARAMETER LinuxUser
    Linux user name to use or create inside Ubuntu. Default: based on your Windows user name.

.PARAMETER UseWsl1
    Force WSL 1. The script switches to WSL 1 on its own when WSL 2 can't run,
    for example in a virtual machine without nested virtualization.

.PARAMETER UpdateSource
    Pull the latest Rockbox source code (git pull) before building.

.PARAMETER OutputDir
    Windows folder where build results are copied. Default: Documents\Rockbox.

.EXAMPLE
    .\Setup-RockboxDev.ps1
    Interactive: asks which compilers to install and whether to do a test build.

.EXAMPLE
    .\Setup-RockboxDev.ps1 -Toolchains arm -Target ipodvideo -Simulator
    Installs the ARM compiler, builds Rockbox for the iPod Video and the Windows simulator.

.EXAMPLE
    .\Setup-RockboxDev.ps1 -Toolchains arm,m68k -Target none
    Only installs the ARM and m68k compilers, without building Rockbox.
#>
[CmdletBinding()]
param(
    [string[]] $Toolchains = @('arm'),
    [string[]] $Target,
    [switch]   $Simulator,
    [switch]   $ShowResults,
    [ValidateSet('32', '64')]
    [string]   $SimulatorArch = '32',
    [string]   $Distro = 'Ubuntu',
    [string]   $LinuxUser,
    [switch]   $UseWsl1,
    [switch]   $UpdateSource,
    [string]   $OutputDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rockbox')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Makes Invoke-WebRequest much faster on PowerShell 5.1
$env:WSL_UTF8          = '1'                  # Makes wsl.exe print UTF-8 instead of UTF-16
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$WorkDir         = Join-Path $env:LOCALAPPDATA 'RockboxDevSetup'
$ScriptDir       = Join-Path $WorkDir 'scripts'
$ResumeTaskName  = 'RockboxDevSetup-Resume'
# Linux user name + password chosen before a restart, encrypted for this Windows user (DPAPI).
# Deleted as soon as the Linux user has been created.
$PendingUserFile = Join-Path $WorkDir 'pending-linux-user.xml'
# Time we asked for a restart. Windows reports newly turned-on features as "Enabled" right
# away, so this is how a second run (without restarting) knows a restart is still needed.
$RestartMarker   = Join-Path $WorkDir 'restart-requested.txt'

# Per toolchain: tools/rockboxdev.sh menu letter, the compiler it installs, the players it
# covers, and a player (tools/configure target) used for the optional test build.
$ToolchainInfo = [ordered]@{
    'arm'        = @{ Letter = 'a'; Compiler = 'arm-elf-eabi-gcc';              TestTarget = 'ipodvideo';    TestName = 'iPod Video'
                      Desc = 'iPods, SanDisk Sansa, Gigabeat, iriver H10, older Sony NWZ (most players)' }
    'm68k'       = @{ Letter = 'm'; Compiler = 'm68k-elf-gcc';                  TestTarget = 'iriverh120';   TestName = 'iriver H120'
                      Desc = 'iriver H1x0/H3x0, iAudio M3/M5/X5, MPIO HD200' }
    'mips'       = @{ Letter = 'i'; Compiler = 'mipsel-elf-gcc';                TestTarget = 'fiiom3k';      TestName = 'FiiO M3K'
                      Desc = 'Ingenic Jz47xx/X1000 players (e.g. FiiO M3K) - may not build under WSL' }
    'arm-linux'  = @{ Letter = 'x'; Compiler = 'arm-rockbox-linux-gnueabi-gcc'; TestTarget = 'samsungypr0';  TestName = 'Samsung YP-R0'
                      Desc = 'Samsung YP-R0/R1, Linux-based Sony NWZ' }
    'mips-linux' = @{ Letter = 'y'; Compiler = 'mipsel-rockbox-linux-gnu-gcc';  TestTarget = 'agptekrocker'; TestName = 'AGPTek Rocker'
                      Desc = 'HiBy OS based players (AGPTek Rocker, xDuoo X3 II/X20, ...)' }
}
# Asked interactively unless given on the command line.
$ToolchainsGiven = $PSBoundParameters.ContainsKey('Toolchains')
$TargetGiven     = $PSBoundParameters.ContainsKey('Target')

# ---------------------------------------------------------------------------
#  Console helpers
# ---------------------------------------------------------------------------
$script:StepNo = 0
function Write-Step([string]$Text) {
    $script:StepNo++
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host (' Step {0}: {1}' -f $script:StepNo, $Text) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Info([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = ([string](Read-Host "  $Question $hint")).Trim().ToLower()
        if ($a -eq '')            { return $Default }
        if ($a -in @('y', 'yes')) { return $true }
        if ($a -in @('n', 'no'))  { return $false }
    }
}

# Starts a program completely independent of this window: no shared console and no inherited
# handles, so it keeps running after the setup window closes. It also skips the Windows shell,
# which would show a security warning for programs on the \\wsl.localhost network-style path.
function Start-Detached([string]$Exe, [string]$WorkingDirectory) {
    if (-not ('RockboxSetup.Detached' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RockboxSetup {
    public static class Detached {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcess(string app, string cmdLine, IntPtr procAttr, IntPtr threadAttr,
            bool inheritHandles, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        const uint DETACHED_PROCESS = 0x8, CREATE_NEW_PROCESS_GROUP = 0x200;
        public static int Start(string exe, string dir) {
            STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
            PROCESS_INFORMATION pi;
            if (!CreateProcess(exe, "\"" + exe + "\"", IntPtr.Zero, IntPtr.Zero, false,
                               DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, IntPtr.Zero, dir, ref si, out pi))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return pi.dwProcessId;
        }
    }
}
'@
    }
    return [RockboxSetup.Detached]::Start($Exe, $WorkingDirectory)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Quotes arguments for a Windows command line (standard CommandLineToArgvW rules).
function ConvertTo-ArgumentString([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -eq '')                 { '""' }
        elseif ($a -notmatch '[\s"]')  { $a }
        else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    return ($quoted -join ' ')
}

# Installing WSL needs administrator rights. Explain how to get them, wait for the user, and stop.
function Stop-NeedsAdmin {
    Write-Host ''
    Write-Note 'WSL (Windows Subsystem for Linux) needs to be installed first, and that'
    Write-Note 'requires administrator rights. This window is not running as administrator.'
    Write-Host ''
    Write-Info 'Please run the setup again as administrator:'
    Write-Info '  - Right-click Setup-RockboxDev.cmd and choose "Run as administrator", or'
    Write-Info '  - Right-click Windows PowerShell, choose "Run as administrator", and run'
    Write-Info "    $PSCommandPath"
    Write-Host ''
    Write-Info 'Use your own Windows account if you can: Ubuntu is installed for the'
    Write-Info 'account that runs the setup.'
    Write-Host ''
    Read-Host '  Press Enter to close' | Out-Null
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

# Arguments that re-run this script with the current settings (used to resume after a restart).
function Get-RelaunchArguments {
    # Pass the answers already given, so the resumed run doesn't ask again.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $PSCommandPath)
    $a += @('-Target', $(if (@($Target).Count) { $Target -join ',' } else { 'none' }))
    $a += @('-Toolchains', ($Toolchains -join ','), '-SimulatorArch', $SimulatorArch,
            '-Distro', $Distro, '-OutputDir', $OutputDir)
    if ($Simulator)    { $a += '-Simulator' }
    if ($ShowResults)  { $a += '-ShowResults' }
    if ($LinuxUser)    { $a += @('-LinuxUser', $LinuxUser) }
    if ($UseWsl1)      { $a += '-UseWsl1' }
    if ($UpdateSource) { $a += '-UpdateSource' }
    return $a
}

# ---------------------------------------------------------------------------
#  WSL helpers
# ---------------------------------------------------------------------------

# Runs wsl.exe and captures its output. Returns @{ Code; Output }. Never throws.
function Invoke-WslCapture([string[]]$WslArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & wsl.exe @WslArgs 2>&1 | ForEach-Object { "$_" -replace "`0", '' }
        return @{ Code = $LASTEXITCODE; Output = ((@($out) | Where-Object { $_ -ne '' }) -join "`n") }
    } finally { $ErrorActionPreference = $old }
}

# Runs wsl.exe, then prints its output (so it also lands in the log). Returns the exit code.
function Invoke-WslLogged([string[]]$WslArgs) {
    $r = Invoke-WslCapture $WslArgs
    if ($r.Output) { $r.Output -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    if ($r.Code -ne 0) { Write-Host "    (wsl.exe $($WslArgs -join ' ') exited with code $($r.Code))" -ForegroundColor DarkGray }
    return $r.Code
}

# Runs wsl.exe attached directly to this console, so progress and prompts
# appear as usual. Returns the exit code.
function Invoke-WslLive([string[]]$WslArgs) {
    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList (ConvertTo-ArgumentString $WslArgs) -NoNewWindow -PassThru
    $null = $p.Handle   # needed so ExitCode is available after the process ends
    $p.WaitForExit()
    return $p.ExitCode
}

# True when the current (Store/MSI) WSL is installed. Checked without running
# wsl.exe, because the built-in stub may wait for a key press when WSL is missing.
function Test-ModernWsl {
    if (Test-Path (Join-Path $env:ProgramFiles 'WSL\wsl.exe')) { return $true }
    try { return [bool](Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction Stop) }
    catch { return $false }
}

function Get-WslDistros {
    if (-not (Test-ModernWsl)) { return @() }
    $r = Invoke-WslCapture '--list', '--quiet'
    if ($r.Code -ne 0) { return @() }
    return @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DistroRegistered { return (Get-WslDistros) -contains $Distro }

function Test-DistroWorks {
    if (-not (Test-DistroRegistered)) { return $false }
    return (Invoke-WslCapture '-d', $Distro, '-u', 'root', '--exec', 'true').Code -eq 0
}

# Runs one of the helper bash scripts inside the distro.
function Invoke-LinuxScript {
    param([string]$Name, [switch]$AsRoot, [string[]]$Arguments = @())
    $user = if ($AsRoot) { 'root' } else { $script:LinuxUserName }
    $wslArgs = @('-d', $Distro, '-u', $user, '--exec', 'bash', "$script:LinuxScriptDir/$Name") + $Arguments
    $code = Invoke-WslLive $wslArgs
    if ($code -ne 0) { throw "The Linux step '$Name' failed (exit code $code). Scroll up to see the error." }
}

# ---------------------------------------------------------------------------
#  Bash helper scripts (written to disk with Unix line endings)
# ---------------------------------------------------------------------------
$BashCommon = @'
set -euo pipefail
# Keep Windows folders (with spaces and brackets) out of PATH; they confuse some build scripts.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# Copy all output to the setup's Linux log (path handed over from Windows through WSLENV).
if [ -n "${RBSETUP_LOG:-}" ]; then
    echo "===== $(date '+%F %T') $(basename "$0") $* (as $(id -un))" >> "$RBSETUP_LOG"
    exec > >(tee -a "$RBSETUP_LOG") 2>&1
    tee_pid=$!
    # On exit, let tee finish writing before the script ends, or the last lines get lost.
    trap 'exec >&- 2>&-; wait $tee_pid' EXIT
fi
trap 'echo "!!! $(basename "$0") failed (exit $?) at line $LINENO: $BASH_COMMAND"' ERR
'@

$BashScripts = @{
'find-user.sh' = @'
# Prints the first regular (uid >= 1000) user account, if any.
awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd
'@

'user.sh' = @'
# Usage: user.sh create <name>   (password is read from stdin)
#        user.sh default <name>  (make <name> the default user, unless one is already set)
mode="$1"; u="$2"
touch /etc/wsl.conf
if [ "$mode" = "create" ]; then
    IFS= read -r pw || true
    pw="${pw%$'\r'}"
    id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
    usermod -aG sudo "$u"
    printf '%s:%s\n' "$u" "$pw" | chpasswd
elif awk '/^\[/{s=($0=="[user]")} s && /^[ \t]*default[ \t]*=/{f=1} END{exit !f}' /etc/wsl.conf; then
    exit 0
fi
# Rewrite the [user] section of /etc/wsl.conf so "wsl" logs in as this user
awk '/^\[/{skip=($0=="[user]")} !skip' /etc/wsl.conf > /etc/wsl.conf.new
printf '\n[user]\ndefault=%s\n' "$u" >> /etc/wsl.conf.new
mv /etc/wsl.conf.new /etc/wsl.conf
'@

'packages.sh' = @'
apt-get update
# Packages from the Rockbox wiki (libgmp-dev is the current name of libgmp3-dev),
# plus the other tools rockboxdev.sh checks for or downloads with.
apt-get install -y git build-essential texinfo bison libtool autoconf flex zip libtool-bin \
    libgmp-dev libmpfr-dev libmpc-dev automake patch perl wget curl ca-certificates \
    xz-utils bzip2 gzip
'@

'source.sh' = @'
# Usage: source.sh <update: 0|1>
cd "$HOME"
if [ -d rockbox/.git ]; then
    echo "Rockbox source already present in ~/rockbox"
    if [ "$1" = "1" ]; then
        git -C rockbox pull --ff-only
    fi
    exit 0
fi
rm -rf rockbox
if timeout 30 git ls-remote git://git.rockbox.org/rockbox HEAD >/dev/null 2>&1; then
    echo "Cloning from git://git.rockbox.org/rockbox ..."
    git clone --progress git://git.rockbox.org/rockbox
else
    echo "git.rockbox.org is not reachable (port 9418 may be blocked); using the GitHub mirror."
    git clone --progress https://github.com/Rockbox/rockbox.git
fi
'@

'toolchain.sh' = @'
# Usage: toolchain.sh <rockbox dir> <letter>:<compiler> ...
repo="$1"; shift
export RBDEV_DOWNLOAD=/tmp/rbdev-dl

# rockboxdev.sh downloads with plain "curl -fLo": no retries, no stall timeout, and a
# broken transfer leaves a partial file that later runs treat as complete.
# Make curl more patient and robust through its config file...
export CURL_HOME=/tmp/rbsetup-curl
mkdir -p "$CURL_HOME"
cat > "$CURL_HOME/.curlrc" <<'EOF'
connect-timeout = 30
retry = 3
retry-delay = 5
retry-all-errors
speed-limit = 10240
speed-time = 60
EOF
# ...and fall back to other GNU mirrors (the default one can be very slow).
mirrors="https://ftp.gnu.org/gnu https://ftpmirror.gnu.org https://mirrors.kernel.org/gnu"

remove_broken_downloads() {
    for f in "$RBDEV_DOWNLOAD"/*; do
        [ -f "$f" ] || continue
        if ! tar -tf "$f" >/dev/null 2>&1; then
            echo "Removing incomplete download: $(basename "$f")"
            rm -f "$f"
        fi
    done
}

for spec in "$@"; do
    letter="${spec%%:*}"; compiler="${spec#*:}"
    if command -v "$compiler" >/dev/null 2>&1; then
        echo "$compiler is already installed - skipping."
        continue
    fi
    for mirror in $mirrors; do
        remove_broken_downloads
        echo "Building toolchain '$letter' ($compiler), downloading from $mirror. This takes a while..."
        (cd "$repo" && GNU_MIRROR="$mirror" RBDEV_TARGET="$letter" ./tools/rockboxdev.sh) 2>&1 \
            | tee /tmp/rbsetup-toolchain-attempt.log || true
        command -v "$compiler" >/dev/null 2>&1 && break
        # rockboxdev.sh exits with success even when a download fails, so check its output.
        if grep -q "couldn't download" /tmp/rbsetup-toolchain-attempt.log; then
            echo "Download failed; trying the next mirror."
            continue
        fi
        break   # a real build error: retrying won't help
    done
    command -v "$compiler" >/dev/null 2>&1 || { echo "ERROR: $compiler was not installed. See the messages above."; exit 1; }
done
'@

'build.sh' = @'
# Usage: build.sh <target> <windows output dir>
target="$1"; winout="$2"
bdir="$HOME/rockbox/build-$target"
mkdir -p "$bdir"; cd "$bdir"
if [ ! -f Makefile ]; then
    ../tools/configure --target="$target" --type=N
fi
make -j"$(nproc)"
make zip
dest="$(wslpath -u "$winout")"
mkdir -p "$dest"
cp -f rockbox.zip "$dest/rockbox-$target.zip"
'@

'sdl.sh' = @'
# Usage: sdl.sh <mingw host triplet>   (runs as root)
# Cross-compiles a static SDL2 for Windows, as described in the Rockbox wiki.
host="$1"
prefix="/usr/local/cross-tools/$host"
apt-get install -y mingw-w64
if [ ! -f "$prefix/lib/libSDL2.a" ]; then
    src="/usr/local/src/SDL2-$host"
    rm -rf "$src"
    git clone --progress --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL "$src"
    mkdir -p "$src/build"; cd "$src/build"
    ../configure --host="$host" --prefix="$prefix"
    make -j"$(nproc)"
    make install
else
    echo "SDL2 for $host is already built - skipping."
fi
# Help Rockbox's configure find the cross-compiled SDL (same links as the wiki).
ln -sf "$prefix/bin/sdl2-config"   "/usr/bin/$host-sdl2-config"
ln -sf "$prefix/lib/libSDL2main.a" /usr/lib/libSDL2main.a
ln -sf "$prefix/lib/libSDL2.a"     /usr/lib/libSDL2.a
if [ -d /usr/include/SDL2 ] && [ ! -L /usr/include/SDL2 ]; then
    echo "WARNING: /usr/include/SDL2 is a real folder (libsdl2-dev?); not replacing it."
else
    ln -sfn "$prefix/include/SDL2" /usr/include/SDL2
fi
'@

'sim.sh' = @'
# Usage: sim.sh <target> <32|64>
# The simulator stays in its build folder: rockboxui.exe runs from there (with simdisk/ next to it).
target="$1"; arch="$2"
if [ "$arch" = "64" ]; then opts="AS6"; else opts="ASW"; fi   # (A)dvanced: (S)imulator + (W)in32 / Win(6)4
bdir="$HOME/rockbox/build-sim-$target-win$arch"
mkdir -p "$bdir"; cd "$bdir"
if [ ! -f Makefile ]; then
    ../tools/configure --target="$target" --type="$opts"
fi
make -j"$(nproc)"
make install
'@
}

function Write-BashScripts {
    New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    foreach ($name in $BashScripts.Keys) {
        $body = "#!/bin/bash`n" + $BashCommon + "`n" + $BashScripts[$name] + "`n"
        [IO.File]::WriteAllText((Join-Path $ScriptDir $name), ($body -replace "`r`n", "`n"), $utf8NoBom)
    }
}

# ---------------------------------------------------------------------------
#  Stage: WSL itself
# ---------------------------------------------------------------------------
function Test-RestartStillPending {
    if (-not (Test-Path $RestartMarker)) { return $false }
    $requested = [datetime]::Parse((Get-Content $RestartMarker -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture,
                                   [Globalization.DateTimeStyles]::RoundtripKind)
    $lastBoot  = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ($lastBoot -gt $requested) { Remove-Item $RestartMarker -ErrorAction SilentlyContinue; return $false }
    return $true
}

function Request-Reboot([string]$Why) {
    if (-not (Test-Path $RestartMarker)) { Set-Content -Path $RestartMarker -Value (Get-Date).ToString('o') }

    # A one-time scheduled task resumes the setup, as administrator, when this user next logs on.
    # (A RunOnce entry would start without administrator rights.) The script deletes the task when it starts.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (ConvertTo-ArgumentString (Get-RelaunchArguments))
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $me
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Resumes the Rockbox development setup after a restart.' -Force | Out-Null

    Write-Host ''
    Write-Note $Why
    Write-Info 'After you log back in, this setup continues by itself.'
    if (Read-YesNo 'Restart the computer now?' $true) {
        Restart-Computer -Force
    } else {
        Write-Info 'Restart when you are ready. The setup continues after you log back in.'
    }
    exit 0
}

function Enable-WslFeatures {
    $restart = $false
    foreach ($f in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($null -eq $feat) { Write-Note "Windows feature '$f' is not available on this system."; continue }
        switch ($feat.State.ToString()) {
            'Enabled'       { Write-Ok "Windows feature '$f' is enabled." }
            'EnablePending' { Write-Info "Windows feature '$f' is waiting for a restart."; $restart = $true }
            default {
                Write-Info "Turning on Windows feature '$f'..."
                try {
                    $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -WarningAction SilentlyContinue
                    if ($r.RestartNeeded) { $restart = $true }
                    Write-Ok "Turned on '$f'."
                } catch {
                    if ($f -ne 'VirtualMachinePlatform') { throw }
                    Write-Note "Could not turn on '$f' ($($_.Exception.Message)). WSL 1 will be used."
                    $script:UseWsl1 = $true
                }
            }
        }
    }
    if (Test-RestartStillPending) {
        Write-Info 'Windows has not restarted since the WSL features were turned on.'
        $restart = $true
    }
    return $restart
}

function Install-ModernWsl {
    if (Test-ModernWsl) { Write-Ok 'The WSL package is installed.'; return }

    # The MSI from Microsoft's GitHub releases works on Windows 10/11 and Windows Server
    # (Server has no Microsoft Store).
    Write-Info 'Downloading the latest WSL from github.com/microsoft/WSL ...'
    $arch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $rel   = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/microsoft/WSL/releases/latest' -Headers @{ 'User-Agent' = 'RockboxDevSetup' }
    $asset = $rel.assets | Where-Object { $_.name -like "*.$arch.msi" } | Select-Object -First 1
    if ($null -eq $asset) { throw "Could not find a WSL installer for $arch in the latest WSL release." }
    $msi = Join-Path $WorkDir $asset.name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $msi
    Write-Info "Installing $($asset.name)..."
    $msiLog = Join-Path $WorkDir 'wsl-msi-install.log'
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$msiLog`"" -Wait -PassThru
    if ($p.ExitCode -eq 3010) { Request-Reboot 'Windows needs to restart to finish installing WSL.' }
    if ($p.ExitCode -ne 0)    { throw "The WSL installer failed with exit code $($p.ExitCode). Details: $msiLog" }
    if (-not (Test-ModernWsl)) { throw 'WSL was installed but cannot be found. Restart Windows and run this script again.' }
    Write-Ok 'WSL installed.'
}

function Install-Distro {
    if ($UseWsl1) {
        Write-Info 'Using WSL 1.'
        Invoke-WslLogged '--set-default-version', '1' | Out-Null
    }
    Write-Info "Downloading and installing $Distro (this can take several minutes, with no progress shown)..."
    Invoke-WslLogged '--install', '-d', $Distro, '--web-download', '--no-launch' | Out-Null

    if (-not (Test-DistroRegistered)) {
        # Older "Store app" style distributions need their launcher to finish registering.
        $launcher = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\{0}.exe' -f ($Distro -replace '[^A-Za-z0-9]', '').ToLower())
        if (Test-Path $launcher) {
            Write-Info 'Finishing the installation...'
            & $launcher install --root | Out-Host
        }
    }
    return (Test-DistroWorks)
}

function Initialize-Wsl {
    Write-Step 'Checking Windows Subsystem for Linux (WSL)'

    if (Test-DistroWorks) { Write-Ok "WSL and $Distro are installed and working."; return }

    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -lt 19041) {
        throw "This Windows build ($build) is too old. You need Windows 10 version 2004 or later, Windows 11, or Windows Server 2022 or later."
    }

    if (Test-IsAdmin) {
        if (Enable-WslFeatures) {
            Request-Reboot 'Windows needs to restart to finish turning on WSL.'
        }
        Install-ModernWsl
    } elseif (-not (Test-ModernWsl)) {
        Stop-NeedsAdmin
    }
    # Otherwise WSL is installed and only the distribution is missing; that needs no admin rights.

    $v = Invoke-WslCapture '--version'
    if ($v.Code -eq 0) { $v.Output -split "`n" | Select-Object -First 3 | ForEach-Object { Write-Info $_ } }

    if (Test-DistroWorks) { Write-Ok "$Distro is installed and working."; return }
    if (Test-DistroRegistered) {
        throw "$Distro is installed but does not start. Open PowerShell, run 'wsl -d $Distro', and read the error. Or run this script with -Distro <another name>."
    }

    if (Install-Distro) { Write-Ok "$Distro installed."; return }

    if (-not $UseWsl1) {
        Write-Note 'WSL 2 could not start. Either virtualization is turned off in the BIOS/UEFI, or'
        Write-Note 'this is a virtual machine without nested virtualization. Trying WSL 1 instead.'
        if (Test-DistroRegistered) { Invoke-WslLogged '--unregister', $Distro | Out-Null }
        $script:UseWsl1 = $true
        if (Install-Distro) { Write-Ok "$Distro installed (WSL 1)."; return }
    }
    throw "Could not install $Distro. Scroll up for the error from wsl.exe."
}

# ---------------------------------------------------------------------------
#  Stage: Linux user
# ---------------------------------------------------------------------------
function Get-SuggestedLinuxUserName {
    $n = $env:USERNAME.ToLower() -replace '[^a-z0-9_-]', ''
    if ($n -notmatch '^[a-z_]') { $n = "rb$n" }
    if ($n.Length -gt 32) { $n = $n.Substring(0, 32) }
    if ($n -in @('rb', 'root')) { $n = 'rockbox' }
    return $n
}

# Asks for the Linux user name and password. Returns a PSCredential.
function Read-LinuxAccount {
    Write-Host ''
    Write-Info 'Ubuntu needs its own user name and password. Linux asks for this password'
    Write-Info 'when you run administrator ("sudo") commands. Make sure you remember it.'
    $name = $LinuxUser
    while (-not $name) {
        $suggest = Get-SuggestedLinuxUserName
        $name = ([string](Read-Host "  Linux user name [$suggest]")).Trim()
        if (-not $name) { $name = $suggest }
        if ($name -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {
            Write-Note 'Use lowercase letters, digits, - and _, and start with a letter.'
            $name = $null
        }
    }
    if ($name -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw "'$name' is not a valid Linux user name. Use lowercase letters, digits, - and _, and start with a letter."
    }
    while ($true) {
        $p1 = Read-Host '  Choose a Linux password (typing is hidden)' -AsSecureString
        $p2 = Read-Host '  Type the password again' -AsSecureString
        $s1 = (New-Object PSCredential 'x', $p1).GetNetworkCredential().Password
        $s2 = (New-Object PSCredential 'x', $p2).GetNetworkCredential().Password
        if (-not $s1)     { Write-Note 'The password cannot be empty.'; continue }
        if ($s1 -cne $s2) { Write-Note 'The passwords do not match. Try again.'; continue }
        return (New-Object PSCredential $name, $p1)
    }
}

# Called before WSL/Ubuntu are installed, so that no questions are left once the long
# (and possibly restarted) part begins. The answer is kept DPAPI-encrypted until used.
function Request-LinuxAccountUpFront {
    if (Test-Path $PendingUserFile) { return }
    if (Test-DistroWorks)          { return }   # existing Ubuntu: handled in Initialize-LinuxUser
    Read-LinuxAccount | Export-Clixml -Path $PendingUserFile
}

function Initialize-LinuxUser {
    Write-Step "Setting up your Linux user in $Distro"

    # Put the helper scripts where Linux can read them and find their Linux path.
    Write-BashScripts
    $r = Invoke-WslCapture '-d', $Distro, '-u', 'root', '--exec', 'wslpath', '-u', $ScriptDir
    if ($r.Code -ne 0 -or -not $r.Output) { throw "Could not access $ScriptDir from inside WSL: $($r.Output)" }
    $script:LinuxScriptDir = $r.Output.Trim()

    $account = $null
    if (Test-Path $PendingUserFile) {
        try { $account = Import-Clixml -Path $PendingUserFile }
        catch { Write-Note 'Could not read the saved Linux user name and password; asking again.' }
    }
    $wanted = if ($account) { $account.UserName } else { $LinuxUser }

    $existing = (Invoke-WslCapture '-d', $Distro, '-u', 'root', '--exec', 'bash', "$script:LinuxScriptDir/find-user.sh").Output.Trim()
    if ($existing -and (-not $wanted -or $wanted -eq $existing)) {
        Invoke-LinuxScript 'user.sh' -AsRoot -Arguments @('default', $existing)
        Invoke-WslCapture '--terminate', $Distro | Out-Null   # so a changed default user takes effect
        Remove-Item $PendingUserFile -ErrorAction SilentlyContinue
        $script:LinuxUserName = $existing
        Write-Ok "Using your existing Linux user '$existing'."
        return
    }

    if (-not $account) { $account = Read-LinuxAccount }
    $name = $account.UserName

    # Send the password on stdin so it never appears on a command line.
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $account.GetNetworkCredential().Password | & wsl.exe -d $Distro -u root --exec bash "$script:LinuxScriptDir/user.sh" create $name | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "Creating the Linux user failed (exit code $code)." }
    Remove-Item $PendingUserFile -ErrorAction SilentlyContinue

    Invoke-WslCapture '--terminate', $Distro | Out-Null   # so the new default user takes effect
    $script:LinuxUserName = $name
    Write-Ok "Created Linux user '$name'."
}

# ---------------------------------------------------------------------------
#  Target selection (asked first, so the long steps can run unattended)
# ---------------------------------------------------------------------------
# Question 1: which cross-compilers to install. Each one takes a while, so only build what's needed.
function Select-Toolchains {
    if ($ToolchainsGiven) { return }
    $names = @($ToolchainInfo.Keys)
    Write-Host ''
    Write-Info 'This installs the tools (cross-compilers) that turn the Rockbox source code'
    Write-Info 'into firmware for music players. Each compiler covers a family of players'
    Write-Info 'and takes a while to build, so choose only the ones you need.'
    Write-Host ''
    Write-Host '  Which cross-compilers do you want to install?' -ForegroundColor Cyan
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ('   {0}) {1,-11} {2}' -f ($i + 1), $names[$i], $ToolchainInfo[$names[$i]].Desc)
    }
    while ($true) {
        $a = ([string](Read-Host '  Numbers separated by commas [1 = arm]')).Trim()
        if (-not $a) { $script:Toolchains = @('arm'); return }
        $picked = @()
        foreach ($part in ($a -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { $picked += $names[$n - 1] }
            elseif ($names -contains $part.ToLower())                                  { $picked += $part.ToLower() }
            else { $picked = $null; break }
        }
        if ($picked) { $script:Toolchains = @($picked | Select-Object -Unique); return }
        Write-Note "Please enter numbers from 1 to $($names.Count), for example: 1  or  1,2"
    }
}

# Question 2: build Rockbox once with each chosen compiler, to confirm the tools work.
# The player for each test build is picked automatically from the compiler.
function Select-TestBuild {
    if ($TargetGiven) { return }
    Write-Host ''
    Write-Info 'After installing, the script can build Rockbox once with each compiler to'
    Write-Info 'confirm that the tools work:'
    Write-Host ''
    Write-Info ('    {0,-11} {1,-15} {2}' -f 'Compiler', 'Test player', 'Built in (inside Ubuntu)')
    foreach ($t in $Toolchains) {
        $i = $ToolchainInfo[$t]
        Write-Info ('    {0,-11} {1,-15} ~/rockbox/build-{2}' -f $t, $i.TestName, $i.TestTarget)
    }
    Write-Host ''
    Write-Info "In File Explorer, ~ is \\wsl.localhost\$Distro\home\<your Linux user name>."
    Write-Info "The finished rockbox-<player>.zip files are copied to $OutputDir,"
    Write-Info 'and that folder opens when the setup is done.'
    if (-not (Read-YesNo 'Do a test build?' $true)) { $script:Target = @(); return }

    $script:Target      = @($Toolchains | ForEach-Object { $ToolchainInfo[$_].TestTarget })
    $script:ShowResults = $true
    if (-not $Simulator) {
        $first = $ToolchainInfo[$Toolchains[0]]
        Write-Host ''
        Write-Info ('The simulator runs Rockbox for the {0} as a Windows program. Building it takes' -f $first.TestName)
        Write-Info ('a few extra minutes. It is built in ~/rockbox/build-sim-{0}-win{1} (inside Ubuntu),' -f $first.TestTarget, $SimulatorArch)
        Write-Info 'and when the setup is done that folder opens and the simulator starts.'
        $script:Simulator = Read-YesNo 'Also build the simulator?' $false
    }
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$stamp    = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$logFile  = Join-Path $WorkDir "setup-$stamp.log"
$linuxLog = Join-Path $WorkDir "setup-$stamp-linux.log"
try { Start-Transcript -Path $logFile | Out-Null } catch { }

# The PowerShell log can't see what runs inside Linux, so the bash helpers write their
# own log. WSLENV passes the variable into WSL, converting the path (/p).
$env:RBSETUP_LOG = $linuxLog
$env:WSLENV = (@(($env:WSLENV -split ':') | Where-Object { $_ -and $_ -notlike 'RBSETUP_LOG*' }) + 'RBSETUP_LOG/p') -join ':'

try {
    Write-Host ''
    Write-Host '  Rockbox development environment setup (WSL)' -ForegroundColor White
    Write-Host '  -------------------------------------------'
    Write-Info ('Windows build {0}, PowerShell {1}, {2}' -f [Environment]::OSVersion.Version.Build, $PSVersionTable.PSVersion, $env:PROCESSOR_ARCHITECTURE)

    # Accept "-Toolchains arm,m68k" / "-Target a,b" whether they arrive as arrays or single strings.
    $Toolchains = @(($Toolchains -join ',') -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    foreach ($t in $Toolchains) {
        if (-not $ToolchainInfo.Contains($t)) {
            throw "Unknown toolchain '$t'. Choose from: $($ToolchainInfo.Keys -join ', ')."
        }
    }
    $Target = @(($Target -join ',') -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -and $_ -ne 'none' })

    # We're running now, so a pending "resume after restart" task is no longer needed.
    if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
        try { Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction Stop } catch { }
    }

    $drive = $env:LOCALAPPDATA.Substring(0, 1)
    $free  = (Get-PSDrive $drive).Free
    if ($free -lt 10GB) {
        Write-Note ('Only {0:N1} GB free on drive {1}:. The setup needs about 10 GB.' -f ($free / 1GB), $drive)
    }

    # Check administrator rights before asking any questions. They are only needed to install WSL.
    $isAdmin = Test-IsAdmin
    Write-Info ('Running as administrator: {0}' -f $(if ($isAdmin) { 'yes' } else { 'no' }))
    if (-not $isAdmin) {
        if (Test-DistroWorks)   { Write-Ok "WSL and $Distro are already installed, so administrator rights are not needed." }
        elseif (Test-ModernWsl) { Write-Ok "WSL is installed; $Distro can be installed without administrator rights." }
        else                    { Stop-NeedsAdmin }
    }

    # All questions come first, so the long part can run unattended (even across a restart).
    Select-Toolchains
    if ($Toolchains -contains 'mips') {
        Write-Note 'The Rockbox wiki says the MIPS toolchain does not currently build under WSL.'
    }
    Select-TestBuild
    if ($Simulator -and -not $Target.Count) {
        Write-Note 'The simulator needs a target to build for; skipping it.'
        $Simulator = $false
    }
    Request-LinuxAccountUpFront

    Initialize-Wsl
    Initialize-LinuxUser

    Write-Step 'Installing build dependencies (apt-get)'
    Invoke-LinuxScript 'packages.sh' -AsRoot
    Write-Ok 'Dependencies installed.'

    Write-Step 'Getting the Rockbox source code'
    Invoke-LinuxScript 'source.sh' -Arguments @($(if ($UpdateSource) { '1' } else { '0' }))
    $repo    = "/home/$script:LinuxUserName/rockbox"
    $repoWin = "\\wsl.localhost\$Distro\home\$script:LinuxUserName\rockbox"
    Write-Ok "Source code is in ~/rockbox (from Windows: $repoWin)"

    Write-Step ('Building cross-compiler(s): {0}' -f ($Toolchains -join ', '))
    Write-Info 'The first build usually takes 10-60 minutes, depending on your computer.'
    $specs = @($Toolchains | ForEach-Object { '{0}:{1}' -f $ToolchainInfo[$_].Letter, $ToolchainInfo[$_].Compiler })
    Invoke-LinuxScript 'toolchain.sh' -AsRoot -Arguments (@($repo) + $specs)
    Write-Ok 'Cross-compiler(s) ready.'

    $buildWord = if ($TargetGiven) { 'Building Rockbox' } else { 'Test build: Rockbox' }
    $zips = @()
    foreach ($t in $Target) {
        Write-Step "$buildWord for '$t'"
        Invoke-LinuxScript 'build.sh' -Arguments @($t, $OutputDir)
        $zips += Join-Path $OutputDir "rockbox-$t.zip"
        Write-Ok "Rockbox built for '$t': $($zips[-1])"
    }

    $simPath = $null; $simDir = $null
    if ($Simulator) {
        $simTarget = $Target[0]
        $mingwHost = if ($SimulatorArch -eq '64') { 'x86_64-w64-mingw32' } else { 'i686-w64-mingw32' }
        Write-Step "Preparing the Windows cross-compiler and SDL2 for the simulator ($SimulatorArch-bit)"
        Invoke-LinuxScript 'sdl.sh' -AsRoot -Arguments @($mingwHost)
        Write-Ok 'SDL2 ready.'

        Write-Step "Building the simulator for '$simTarget'"
        Invoke-LinuxScript 'sim.sh' -Arguments @($simTarget, $SimulatorArch)
        $simDir  = "$repoWin\build-sim-$simTarget-win$SimulatorArch"
        $simPath = "$simDir\rockboxui.exe"
        Write-Ok "Simulator built: $simPath"
    }

    # ---- Summary ------------------------------------------------------------
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host '  All done! Your Rockbox development environment is ready.' -ForegroundColor Green
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host ''
    Write-Host "  Compilers:    $($Toolchains -join ', ')"
    if ($zips) {
        Write-Host ("  {0,-13} {1}" -f $(if ($TargetGiven) { 'Builds:' } else { 'Test builds:' }), $zips[0])
        $zips | Select-Object -Skip 1 | ForEach-Object { Write-Host "                $_" }
        Write-Host '                (To install one, unzip it to the root folder of that player.)'
    }
    if ($simPath) {
        Write-Host "  Simulator:    $simPath"
        Write-Host '                (Double-click to run. If Windows shows a security warning for this'
        Write-Host '                location, click Run: it is the program you just built.)'
    }
    Write-Host "  Source code:  $repoWin"
    Write-Host ''
    Write-Host '  To build Rockbox for your own player, open Ubuntu (type "wsl" in a terminal) and run:' -ForegroundColor Cyan
    Write-Host '      mkdir -p ~/rockbox/build-myplayer && cd ~/rockbox/build-myplayer'
    Write-Host '      ../tools/configure        (pick your player from the list)'
    Write-Host '      make -j$(nproc) && make zip'
    if ($zips) {
        Write-Host '  To rebuild an existing build after changing the code:' -ForegroundColor Cyan
        Write-Host "      cd ~/rockbox/build-$($Target[0]) && make -j`$(nproc) && make zip"
    }
    Write-Host ''
    Write-Host '  New to building Rockbox, or not sure how to use the configure script? See:' -ForegroundColor Cyan
    Write-Host '      https://www.rockbox.org/wiki/HowToCompile.html'
    Write-Host ''
    if ($ShowResults -and $zips) {
        Write-Info "Opening $OutputDir ..."
        Start-Process explorer.exe -ArgumentList "`"$OutputDir`""
    }
    if ($ShowResults -and $simPath) {
        Write-Info "Opening $simDir ..."
        Start-Process explorer.exe -ArgumentList "`"$simDir`""
        Write-Info 'Starting the simulator...'
        # The simulator finds simdisk\ relative to its working directory.
        try { Start-Detached $simPath $simDir | Out-Null }
        catch { Write-Note "Could not start the simulator: $($_.Exception.Message)" }
    }
    Write-Host "  Log files: $logFile"
    Write-Host "             $linuxLog"
}
catch {
    Write-Host ''
    Write-Host "  SETUP STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Fix the problem above, then run the script again. Finished steps are skipped.' -ForegroundColor Red
    Write-Host "  Log files: $logFile"
    Write-Host "             $linuxLog"
    # Full details for troubleshooting (goes into the log file too).
    Write-Host ($_ | Out-String) -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
try { Stop-Transcript | Out-Null } catch { }
