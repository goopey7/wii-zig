Windows is supported through Arch Linux on WSL, but you may have trouble running Tracy.
[Click here for the Installation Guide.](https://wiki.archlinux.org/title/Install_Arch_Linux_on_WSL)
Once installed, follow the same steps below.

## Building on Arch Linux

### Prerequisites

**Zig 0.15.2**

As of writing this 0.15.2 is the latest release
```sh
sudo pacman -S zig
```

**Dolphin Emulator** is required for `zig build run` and `zig build test`.

```sh
sudo pacman -S dolphin-emu
```

MMU must be enabled in Dolphin otherwise memory exception crashes won't be caught by the crash
handler. In `~/.config/dolphin-emu/Dolphin.ini` under `[Core]`:

```ini
[Core]
MMU = True
```

To receive output logs in Dolphin, OSREPORT needs to be enabled. In `~/.config/dolphin-emu/Logger.ini` under `[Logs]`:
```ini
[Logs]
OSREPORT = True
```

The following packages are required to build the Tracy profiler server:

```sh
sudo pacman -S cmake gcc libxinerama
```

**Rust** is required to build the debug stacktrace tool:

```sh
sudo pacman -S rustup
rustup default stable
```

### Build
devkitPPC and libogc are downloaded automatically by Zig the first time you build.

Output binaries are placed in `./zig-out/`:
- `wii-zig.elf` is the ELF with full debug info (used by the stacktrace tool)
- `wii-zig.dol` is a stripped down format deployed to the Wii or Dolphin

### Build commands

| Command | Description |
|---|---|
| `zig build` | Compile the application |
| `zig build run` | Build and run in Dolphin emulator |
| `zig build deploy` | Build and deploy to a physical Wii |
| `zig build test` | Build and run unit tests in Dolphin headlessly |
| `zig build test-junit` | Same as `test`, but writes a JUnit XML report to `./zig-out/test-results.xml` |
| `zig build -Dtracy=true` | Build with Tracy profiler enabled |

### Deploying to hardware

Set the `WIILOAD` environment variable to your Wii's IP address before running `zig build deploy`:

```sh
WIILOAD=<wii-ip> zig build deploy
```

### Stacktrace tool

The `debug/` directory contains a Rust tool that receives crash reports sent over the network from
the Wii and resolves them to source locations. Build it once:

```sh
cargo build --release --manifest-path debug/Cargo.toml
```

The tool starts automatically when you run `zig build run` or `zig build deploy`.
Stacktraces will appear in your terminal when the Wii panics or crashes.

> **Note:** The dev machine's IP address is hardcoded as `DEV_MACHINE_IP` in
> `src/platform/root.zig`. Update it there before building since it is used for both
> crash reports and sending CSV benchmark results.

### Tracy profiler server gui

In order to profile a build with Tracy enabled, you'll need to build the Tracy server gui.

```sh
cmake -B tracy/profiler/build tracy/profiler
cmake --build tracy/profiler/build --parallel
```

The binary will be at `tracy/profiler/build/tracy-profiler`.
Run it and connect while the application is running to capture live profiling data.
