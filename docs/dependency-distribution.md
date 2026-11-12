# Dependency Distribution

CodeDiff uses a native diff library. Linux builds with OpenMP enabled also need GCC's OpenMP runtime, `libgomp.so.1`, for parallel character-level diff computation. **OpenMP is a native parallel-computing library, not an AI-agent or OMP integration.**

The installer can use an existing Linux runtime or download one alongside the diff library. This reduces missing-library failures; it does not guarantee compatibility with every Linux distribution, C library, architecture, or Neovim environment.

## Download sources and filenames

The diff library and Linux runtime come from [esmuellert/codediff.nvim releases](https://github.com/esmuellert/codediff.nvim/releases), not this fork's release page. Their version is the plugin root's [`VERSION`](../VERSION), read by [`codediff.version`](../lua/codediff/version.lua).

| Component | Release asset | Installed in the plugin root as |
| --- | --- | --- |
| Diff library | `libvscode_diff_{os}_{arch}_{version}.{ext}` | `libvscode_diff_{version}.{ext}` |
| Linux OpenMP runtime | `libgomp_linux_{arch}_{version}.so.1` | `libgomp.so.1` |

The release URL is `https://github.com/esmuellert/codediff.nvim/releases/download/v{version}/{asset}`. Platform names are `linux`, `macos`, `windows`, and `android`; architecture names are `x64` and `arm64`. Extensions are `so`, `dylib`, and `dll` as appropriate. Termux is detected as Android, not ordinary Linux. Detection rules live in [`codediff.core.installer.common`](../lua/codediff/core/installer/common.lua); detecting a platform does not establish that a compatible release asset is available.

An unversioned `libvscode_diff.so`, `libvscode_diff.dylib`, or `libvscode_diff.dll` in the plugin root is also recognized as a manual build. See the [build guide](BUILD.md) for source-build requirements and commands.

### Separately versioned watcher

Live refresh also uses `codediff-watcher`, downloaded from [esmuellert/codediff releases](https://github.com/esmuellert/codediff/releases). Its version is pinned independently in [`codediff.core.installer.watcher`](../lua/codediff/core/installer/watcher.lua), not read from `VERSION`.

Watcher assets are `codediff-watcher-{version}-{os}-{arch}.tar.gz` on Unix and `.zip` on Windows, under the release tag `v{version}`. The extracted executable is installed as `codediff-watcher_{version}` (with `.exe` on Windows). Extraction needs `tar` on Unix or PowerShell on Windows.

The watcher installer first checks `CODEDIFF_WATCHER_PATH`, an unversioned executable in the plugin root, the pinned version there, and then `codediff-watcher` on `PATH`. Setting `CODEDIFF_WATCHER_NO_AUTO_INSTALL=1` disables its download. Android has no watcher release in this installer. Installation failures fall back to polling; this fallback does not replace the required diff library.

## Installation and error behavior

The diff loader in [`codediff.core.diff`](../lua/codediff/core/diff.lua) invokes [`codediff.core.installer.libvscode_diff`](../lua/codediff/core/installer/libvscode_diff.lua) when an installation or update is needed. You can also run:

```vim
:CodeDiff install
```

Use `:CodeDiff install!` only when you intend to force a fresh diff-library download. Downloads require write access to the plugin root and network access to GitHub. The shared downloader prefers `curl`, then `wget`, with PowerShell as the Windows fallback.

The main library is downloaded to a temporary file and renamed into place. Missing version information, unsupported architecture, download failures, and final rename failures are reported as errors and return failure. An installer success does **not** prove the library can be loaded: the subsequent FFI load can still fail because of ABI or runtime dependencies.

### Linux runtime detection

The OpenMP-runtime check runs only for platforms detected as `linux`:

1. If a readable `libgomp.so.1` already exists in the plugin root, keep it.
2. If Neovim's resolved executable path starts with `/nix/store`, request a bundled runtime rather than relying on the host's library cache.
3. Otherwise, query `ldconfig -p` for `libgomp.so.1`. A match skips the download. No match, or an unavailable `ldconfig`, triggers bundling.
4. Download the matching `libgomp_linux_{arch}_{version}.so.1` to `libgomp.so.1.tmp`, then rename it to `libgomp.so.1`.

This is an availability heuristic, not a load or ABI test. It does not use `ffi.load("gomp")` to detect the system runtime. Environment overrides, a different loader, or an incompatible cached/bundled library can still cause load failures.

The runtime check also runs when `install` finds an existing current diff library or a manual build. However, the automatic update check treats an unversioned manual build as up to date, so it does not automatically repair that build's runtime dependencies.

If the **libgomp** download or rename fails, the installer warns and continues; the plugin may still fail to load without a usable runtime. Architecture/version errors in the runtime helper are reported, but its result is not propagated by the main installer. Do not interpret a successful `:CodeDiff install` as confirmation that OpenMP dependencies are resolved.

## Build and release configuration

The current workflow chain is:

- [`build-and-test.yml`](../.github/workflows/build-and-test.yml) selects platform/architecture builds.
- [`_platform-linux.yml`](../.github/workflows/_platform-linux.yml) builds in CentOS 7 for a glibc 2.17 baseline and collects `libgomp.so.1` alongside the diff library.
- [`release.yml`](../.github/workflows/release.yml) delegates asset naming and checksum-manifest creation to [`assemble-assets/action.yml`](../.github/actions/release/assemble-assets/action.yml).

The Linux OpenMP build configures `$ORIGIN` as the library search path so a runtime beside the diff library can be resolved. The ELF dynamic loader also considers environment settings, cache entries, and system paths; this is not an unconditional preference over all system libraries. See [ld.so(8)](https://man7.org/linux/man-pages/man8/ld.so.8.html) for the complete search rules.

The glibc baseline is a build target, not a promise that these binaries work on every newer system or on musl-based distributions. The installer does not bundle glibc. It also does not download macOS `libomp` or Windows OpenMP runtimes. Non-Linux runtime requirements depend on how the selected library was built. The [Android workflow](../.github/workflows/_platform-android.yml) disables OpenMP; Linux `libgomp` assets are not Android runtimes.

## Read-only diagnostics

In Neovim, with CodeDiff on `runtimepath`, inspect the configured version and library location without invoking installation:

```vim
:lua print(require("codediff.version").VERSION)
:lua print(require("codediff.core.path").get_plugin_root())
:lua print(require("codediff.core.installer.libvscode_diff").get_lib_path())
```

`get_lib_path()` reports the installer's selected path, not proof of a successful load. Review `:messages` for the actual download or loader error.

On Linux, substitute the exact trusted library path reported above:

```sh
readelf -d /path/to/plugin/libvscode_diff_VERSION.so
ldconfig -p
ldd /path/to/plugin/libvscode_diff_VERSION.so
```

`readelf` shows `NEEDED` entries and any `RPATH`/`RUNPATH`. `ldconfig -p` shows the host's cache. `ldd` shows dependency resolution in the shell's environment; it may differ from Neovim's environment, especially with Nix. Only use `ldd` on binaries you trust. These diagnostics do not require deleting or replacing any installed library.

## Manual recovery

For a missing `libgomp.so.1` error:

1. Check `:messages` for the failed download URL or dependency error. Confirm that the selected diff library matches the plugin's `VERSION` and target ABI.
2. If using system libraries, install the distribution's GCC OpenMP runtime package using its package manager (for example, `libgomp1` on Debian/Ubuntu). A host package may not be visible to a Nix-provided Neovim.
3. Alternatively, download `libgomp_linux_{arch}_{version}.so.1` from the same upstream release as the diff library. Select the matching architecture, then place it in the actual plugin root under the exact name `libgomp.so.1`. Do not use a wildcard rename or copy a runtime from a different architecture. Preserve any existing library before intentionally replacing it.
4. For offline installation of the diff library, download the corresponding asset from that release and place it in the plugin root as `libvscode_diff_{version}.{ext}`. Inspect downloaded assets and verify a published checksum when available before loading them. Automatic downloads do not currently validate checksums.
5. If no compatible binary is available, follow the [build guide](BUILD.md) to build for your environment. A build without OpenMP does not need its runtime for parallel diff computation.

Restart Neovim after intentionally replacing a native library. A missing-runtime warning and a glibc/architecture mismatch are different problems; bundling `libgomp` alone does not resolve the latter.

## See also

- [Installation](../README.md#installation)
- [Build System Guide](BUILD.md)
- [Version Management](VERSION_MANAGEMENT.md)
- [Performance](performance.md)
