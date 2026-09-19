# Rockbox development setup for Windows (WSL)

This script installs the tools (cross-compilers) you need to build
[Rockbox](https://www.rockbox.org/) on Windows 10, Windows 11 or Windows Server 2022+.
It follows the Rockbox wiki page
[Windows10CrossCompiler](https://www.rockbox.org/wiki/Windows10CrossCompiler), and the
whole process is automatic:

1. Installs **WSL** (Windows Subsystem for Linux) if you don't have it yet
2. Installs **Ubuntu** and creates your Linux user
3. Installs the build tools (`apt-get`)
4. Downloads the **Rockbox source code** into `~/rockbox`
5. Builds the **cross-compilers** you choose with `tools/rockboxdev.sh`
6. *(Optional)* Does a **test build** of Rockbox with each compiler to confirm the tools
   work, and copies the result (`rockbox-<player>.zip`) to `Documents\Rockbox`
7. *(Optional)* Builds the **simulator** as a Windows program (`rockboxui.exe`)

## Quick start

1. Download or copy this folder to your PC.
2. Right-click **`Setup-RockboxDev.cmd`** and choose **Run as administrator**.
3. Answer the questions:
   1. **Which cross-compilers to install.** Each compiler covers a family of players
      and takes a while to build, so pick only the ones you need. `arm` (the default:
      just press Enter) covers iPods, Sansas and most other players.
   2. **Whether to do a test build.** The script picks a player for each compiler
      (for example the iPod Video for `arm`) and builds Rockbox for it. If that works,
      the tools work. The question shows where each build happens (for example
      `~/rockbox/build-ipodvideo` inside Ubuntu). The finished `rockbox-<player>.zip`
      files are copied to `Documents\Rockbox`, which opens when the setup is done.
   3. *(If you chose a test build)* whether to also build the Windows simulator. It
      stays in its build folder inside Ubuntu (for example
      `~/rockbox/build-sim-ipodvideo-win32`). At the end, that folder opens in File
      Explorer and the simulator starts, so you can try Rockbox right away.
   4. *(New Ubuntu only)* a Linux user name and password.

After the questions, the script runs on its own.

| Compiler | Players | Test build |
|---|---|---|
| `arm` | iPods, SanDisk Sansa, Gigabeat, iriver H10, older Sony NWZ | iPod Video (`ipodvideo`) |
| `m68k` | iriver H1x0/H3x0, iAudio M3/M5/X5, MPIO HD200 | iriver H120 (`iriverh120`) |
| `mips` | Ingenic Jz47xx/X1000 players such as the FiiO M3K (the wiki says this one may not build under WSL) | FiiO M3K (`fiiom3k`) |
| `arm-linux` | Samsung YP-R0/R1, Linux-based Sony NWZ | Samsung YP-R0 (`samsungypr0`) |
| `mips-linux` | HiBy OS players (AGPTek Rocker, xDuoo X3 II/X20, …) | AGPTek Rocker (`agptekrocker`) |

> **Administrator rights** are only needed the first time, to install WSL. The
> script checks this first. If WSL is missing and the window isn't running as
> administrator, it tells you to run it again as administrator, waits for you to
> press Enter, and closes. Once WSL is installed, a normal double-click is enough.

> **Restart:** if WSL wasn't installed, Windows needs to restart once. The script
> asks before restarting and picks up where it left off after you log back in. A
> one-time scheduled task named `RockboxDevSetup-Resume` does this, and it deletes
> itself when it runs. Until the Linux user is created, the Linux user name and
> password are kept in `%LOCALAPPDATA%\RockboxDevSetup\pending-linux-user.xml`,
> encrypted so only your Windows account can read them. The file is deleted once
> it has been used.

**How long it takes:** the first run takes 20–90 minutes, most of it building the
cross-compilers. Later runs skip the finished steps. Running it again to add another
compiler only builds the new one.

## Running from PowerShell (more options)

Any question you answer with an option on the command line isn't asked.

```powershell
# Interactive (same as double-clicking the .cmd)
powershell -ExecutionPolicy Bypass -File .\Setup-RockboxDev.ps1

# Install the ARM and m68k compilers only, no test build
powershell -ExecutionPolicy Bypass -File .\Setup-RockboxDev.ps1 -Toolchains arm,m68k -Target none

# Install the ARM compiler and build for your own player (plus the Windows simulator)
powershell -ExecutionPolicy Bypass -File .\Setup-RockboxDev.ps1 -Toolchains arm -Target sansaclipplus -Simulator

# Get the latest Rockbox code, then rebuild
powershell -ExecutionPolicy Bypass -File .\Setup-RockboxDev.ps1 -Toolchains arm -Target ipodvideo -UpdateSource
```

| Option | What it does |
|---|---|
| `-Toolchains arm,m68k` | Cross-compilers to install: `arm`, `m68k`, `mips`, `arm-linux`, `mips-linux` (see the table above). |
| `-Target <names>` | Build Rockbox for these players instead of the automatic test build (`ipodvideo`, `ipod6g`, `sansaclipplus`, …; separate several with commas). `none` skips building. The names are listed on the [TargetStatus](https://www.rockbox.org/wiki/TargetStatus) page and by `tools/configure`. |
| `-Simulator` | Also build the Windows simulator, for the first player. |
| `-ShowResults` | When done, open the output folder and start the simulator (if built). Switched on automatically when you choose a test build. |
| `-UpdateSource` | Run `git pull` on the Rockbox source first. |
| `-OutputDir <folder>` | Where the finished files go (default `Documents\Rockbox`). |
| `-LinuxUser <name>` | Linux user name to use or create. |
| `-Distro <name>` | WSL distribution to use (default `Ubuntu`). |
| `-UseWsl1` | Force WSL 1. The script also falls back to WSL 1 by itself when WSL 2 can't run. |

## Where things end up

| What | Where |
|---|---|
| Rockbox builds (test builds, or the players you chose with `-Target`) | `Documents\Rockbox\rockbox-<player>.zip` |
| Simulator | `\\wsl.localhost\Ubuntu\home\<linux user>\rockbox\build-sim-<player>-win32\rockboxui.exe` (it needs the `simdisk` folder next to it). When you double-click it, Windows may show a security warning because the file is on the WSL drive. Click **Run**: it's the program you built. |
| Source code | `\\wsl.localhost\Ubuntu\home\<linux user>\rockbox` (you can open this path in File Explorer) |
| Build folders | `~/rockbox/build-<player>` and `~/rockbox/build-sim-<player>-win32` |
| Logs | `%LOCALAPPDATA%\RockboxDevSetup\setup-<time>.log` (Windows side) and `setup-<time>-linux.log` (everything that ran inside Ubuntu: apt, git, compiler and Rockbox builds). If the WSL installer fails, see `wsl-msi-install.log`. |

## Building Rockbox for your player

Once the tools are installed, open Ubuntu by typing `wsl` in a terminal (or open
"Ubuntu" from the Start menu). Make a build folder and run `configure`, which lists
all the players so you can pick yours:

```bash
mkdir ~/rockbox/build-myplayer && cd ~/rockbox/build-myplayer
../tools/configure
make -j$(nproc) && make zip
```

To rebuild after changing the code, run `make -j$(nproc) && make zip` again in that
folder.

Both kinds of simulator can be built:
- **Linux simulator:** choose **S** (Simulator) in `configure`, then run `make` and
  `make install`. The script installs Ubuntu's `libsdl2-dev` for this. It runs inside
  Ubuntu; recent WSL versions show its window on the Windows desktop.
- **Windows simulator (`rockboxui.exe`):** choose **A** (Advanced), then **S** and **W**.
  This needs the cross-compiled Windows SDL2, which the script sets up when you choose
  the simulator. The test build folders (for example `~/rockbox/build-ipodvideo`) work the
same way.

New to this, or not sure what to answer in `configure`? The Rockbox wiki's
[HowToCompile](https://www.rockbox.org/wiki/HowToCompile.html) page walks through it.

## Troubleshooting

- **"WSL 2 could not start… trying WSL 1"**: this is normal inside virtual machines
  without nested virtualization, and on PCs where virtualization is turned off in the
  BIOS/UEFI. WSL 1 works, just more slowly.
- **Security software**: the wiki notes that builds are faster when Windows Defender
  real-time scanning isn't slowing them down. This script keeps everything inside the
  Linux file system, which avoids most of that cost.
- **`git://git.rockbox.org` blocked**: some networks block git's port 9418. The script
  then downloads from the official GitHub mirror (`github.com/Rockbox/rockbox`) instead.
- **Your account isn't an administrator**: installing WSL needs an administrator, and
  WSL distributions belong to the Windows account that runs the setup. If you run it
  as administrator with a *different* account, Ubuntu is installed for that account,
  not yours. Instead, ask an admin to install WSL first
  (`wsl --install --no-distribution` in an administrator PowerShell). Then run this
  script normally from your own account; it installs Ubuntu for you without admin
  rights.
- **Something failed**: read the red message and the lines above it, fix the problem,
  and run the script again. Finished steps are skipped.
