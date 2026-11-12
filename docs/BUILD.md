# Build System Guide

Most users do not need to compile the native diff library. See [automatic installation](../README.md#automatic-installation) for the upstream binaries used by this fork.

Run the commands below from the repository root.

## Requirements

- A C11 compiler and the platform's development tools/SDK.
- For CMake builds: CMake 3.15 or newer and a build tool supported by the selected generator. The root `Makefile` also requires Make.
- For standalone Unix builds: Bash and standard command-line tools. The script honors `CC`, otherwise it tries `cc`, `gcc`, then `clang`.
- For standalone Windows builds: PowerShell and MSVC, Clang, or MinGW-w64 GCC on `PATH`. Use a Visual Studio Developer Command Prompt for MSVC.

utf8proc is bundled; it does not need a separate installation. OpenMP is optional and enabled when detected. Compiler minimum versions and compatibility with other compilers are not guaranteed here; the compiler must support the C11 flags used by the chosen build method.

## Standalone build (no CMake)

On Unix/Linux/macOS:

```bash
./build.sh
```

On Windows:

```cmd
build.cmd
```

These checked-in scripts compile the bundled sources and copy `libvscode_diff.so`, `libvscode_diff.dylib`, or `libvscode_diff.dll` to the plugin root. Close Neovim before replacing a loaded DLL on Windows.

## CMake build

On Unix/Linux/macOS:

```bash
make build
```

Or invoke CMake directly:

```bash
cmake -B build -S .
cmake --build build --config Release
```

The direct commands also work from a Windows developer shell with a suitable CMake generator. To disable optional OpenMP detection, configure with:

```bash
cmake -B build -S . -DENABLE_OPENMP=OFF
```

CMake generates the root Make wrappers and standalone build scripts during configuration. Native sources, bundled utf8proc, and C tests live in [`libvscode-diff/`](../libvscode-diff/); the standalone entry points are at the repository root, not inside that directory.

## Tests and maintenance

Build the library before running Lua tests. The Lua suite needs Neovim and Git; see the [test suite guide](../tests/README.md) for prerequisites, test layout, selectors, and Windows commands.

```bash
make test                       # Build and run C + Lua tests
make test-c                     # Build and run C tests
make test-lua                   # Lua suite (does not build first)
./tests/run_tests.sh unit        # One Lua layer
./tests/run_tests.sh integration
./tests/run_tests.sh e2e
```

For C tests with CMake directly, build first, then run:

```bash
ctest --test-dir build --output-on-failure -C Release
```

The root Makefile also provides `make lint` and `make format` for Lua (requires StyLua), and `make clean` to remove the CMake build directory and root Unix native libraries. Cleaning does not remove every standalone-build artifact or the Windows DLL.

## Troubleshooting

- **CMake not found:** use a standalone script, or install CMake.
- **No compiler found:** install the platform development tools, such as `build-essential` on Debian/Ubuntu, Xcode Command Line Tools on macOS, or Visual Studio/MinGW-w64 on Windows.
- **Download/install problems:** see [manual installation](../README.md#manual-installation) and [dependency distribution](dependency-distribution.md).
