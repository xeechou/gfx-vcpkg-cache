# Vulkan SDK Debian packages

**Build split `.deb` packages from the LunarG Vulkan SDK** and distribute them
via GitHub Actions release/artifacts.

The current packaging model builds four packages from a single LunarG SDK tree:

- `libvulkan1` — Vulkan loader runtime
- `libvulkan-dev` — loader development symlink + build metadata
- `vulkan-headers` — core Vulkan headers and API registry
- `vulkan-sdk` — remaining SDK tools, layers, shader tooling, SPIR-V tooling,
  tracing tools, helper libraries, and related metadata

The SDK payload is still installed under `/usr` (`bin`, `include`, `lib`,
`share`). For compatibility, the packaging keeps the SDK's canonical runtime
libraries in `/usr/lib` so upstream tool binaries continue to resolve
`$ORIGIN/../lib` as shipped, while also adding symlinks under
`/usr/lib/x86_64-linux-gnu` and its `pkgconfig/` / `cmake/` subdirectories for
consumers that expect the conventional multiarch layout.

The LunarG tarball is fetched straight from LunarG's official download server,
so there is no source code in this repository — only the packaging logic.

> **Current status:** the package split now breaks out the core loader/runtime
> identities into real packages (`libvulkan1`, `libvulkan-dev`,
> `vulkan-headers`) and leaves the remaining SDK payload in `vulkan-sdk`.
> This is a safer direction than the original monolithic `vulkan-sdk`
> replacement, but `vulkan-sdk` still overlaps with many distro shader/tooling
> packages and may still need additional future splits. See
> [Findings so far](#findings-so-far).

---

## Layout

```text
../.github/workflows/
└── build-deb.yml          # repo-level GitHub Actions: fetch → build → upload
.
├── build-deb.sh           # build four .debs from a decompressed SDK tree
├── control                # historical note for the old monolithic package
├── control.d/             # split package control templates
│   ├── libvulkan1
│   ├── libvulkan-dev
│   ├── vulkan-headers
│   └── vulkan-sdk
├── copyright              # Debian copyright file template
├── install-or-recover.sh  # local helper: install split .debs or roll back
└── scripts/
    └── fetch-sdk.sh       # download + decompress the LunarG SDK tarball
```

## Building locally

All in one shot (download + build):

```bash
./scripts/fetch-sdk.sh
./build-deb.sh
```

This produces:

```text
./libvulkan1_1.4.357.1-1local_amd64.deb
./libvulkan-dev_1.4.357.1-1local_amd64.deb
./vulkan-headers_1.4.357.1-1local_all.deb
./vulkan-sdk_1.4.357.1-1local_amd64.deb
```

Or build a different SDK version:

```bash
SDK_VERSION=1.3.290.0 ./scripts/fetch-sdk.sh
SDK_VERSION=1.3.290.0 ./build-deb.sh
```

Everything is overridable via environment variables (see the header comments
in each script). When `SDK_VERSION` is not set explicitly, the scripts and CI
use the checked-in `./SDK_VERSION` file as the default source of truth:

| Variable       | Default        | Purpose                                  |
|----------------|----------------|------------------------------------------|
| `SDK_VERSION`  | `./SDK_VERSION` | LunarG SDK version / on-disk tree name  |
| `SDK_URL`      | derived        | full tarball URL (overrides version)     |
| `ARCH`         | `amd64`        | Debian architecture for arch packages    |
| `REVISION`     | `$SDK_VERSION-1local` | Debian revision string             |
| `OUT`          | `$PWD`         | where the `.deb` files are written       |
| `SDKROOT`      | `./$SDK_VERSION` | path to an extracted SDK tree          |
| `STAGE_BASE`   | `./stage`      | base directory for package staging roots |
| `MAINTAINER`   | local default  | Debian `Maintainer` field value          |

If you already have the SDK extracted (for example `~/vulkansdk/1.4.357.1`),
skip the download and build straight from it:

```bash
SDKROOT=~/vulkansdk/1.4.357.1 ./build-deb.sh
```

> **Note on custom URLs:** if you pass `SDK_URL` for a version other than
> `SDK_VERSION`, set `SDK_VERSION` to match the tarball's leading directory so
> the extract/build paths line up.

## GitHub Actions

The repository-level workflow `../.github/workflows/build-deb.yml` builds this
sub-project's packages, uploads them as build artifacts, and (on release)
attaches them to the release. The workflow runs the fetch/build scripts with
`vulkan-sdk-deb` as its working directory so additional package sub-projects can
be added alongside this one later.

Trigger it:

- **Manually** — *Actions → Build Debian Package → Run workflow*, supplying
  `sdk_version`, an optional `sdk_url`, and `arch`.
- **On push** to `main` — rebuilds the default version recorded in `SDK_VERSION`.
- **On release publish** — builds the version selected by workflow input or the
  checked-in `SDK_VERSION` file, and attaches the built `.deb` files to a
  `vulkan-sdk-*` release tag.

Artifact contents: the built `.deb` files plus `build-info.txt` (version,
source URL, commit, build time).

### Example: trigger a build for a new SDK version

```bash
gh workflow run build-deb.yml -f sdk_version=1.5.999.9
gh run watch
gh run view --web
```

## Installing the packages

```bash
# Install the locally-built split packages:
sudo ./install-or-recover.sh install

# Roll back to the distro packages (restores pre-install apt state):
sudo ./install-or-recover.sh recover

# Or install them directly with apt:
sudo apt install \
  ./libvulkan1_1.4.357.1-1local_amd64.deb \
  ./libvulkan-dev_1.4.357.1-1local_amd64.deb \
  ./vulkan-headers_1.4.357.1-1local_all.deb \
  ./vulkan-sdk_1.4.357.1-1local_amd64.deb
```

The split keeps the loader/runtime identities in real packages while still
bundling the remaining SDK payload into `vulkan-sdk`.

## Package contents

### `libvulkan1`

Owns only the Vulkan loader runtime:

- `/usr/lib/libvulkan.so.1*`
- compatibility symlinks under `/usr/lib/x86_64-linux-gnu/`

### `libvulkan-dev`

Owns only the Vulkan loader development surface:

- `/usr/lib/libvulkan.so`
- `/usr/lib/pkgconfig/vulkan.pc`
- `/usr/lib/cmake/VulkanLoader/*`
- compatibility links under `/usr/lib/x86_64-linux-gnu/`

### `vulkan-headers`

Owns the core Vulkan headers and API registry:

- `/usr/include/vulkan/*`
- `/usr/include/vk_video/*`
- `/usr/share/cmake/VulkanHeaders/*`
- `/usr/share/vulkan/registry/*`

### `vulkan-sdk`

Owns the remaining SDK payload:

- tools such as `vulkaninfo`, `vkcube`, `vkconfig`
- validation and utility layers
- shader compilers (`glslang`, `glslc`, `slang`, `dxc`)
- SPIR-V tooling and related libraries
- gfxreconstruct
- SDK helper headers/libraries/metadata outside the core Vulkan loader/header set

## Findings so far

### 1. The split build now succeeds locally

The package set currently builds successfully with:

```bash
./scripts/fetch-sdk.sh
./build-deb.sh
```

and produces:

```text
./libvulkan1_1.4.357.1-1local_amd64.deb
./libvulkan-dev_1.4.357.1-1local_amd64.deb
./vulkan-headers_1.4.357.1-1local_all.deb
./vulkan-sdk_1.4.357.1-1local_amd64.deb
```

### 2. Splitting out `libvulkan1`, `libvulkan-dev`, and `vulkan-headers` matches distro package identities better

Inspecting the distro/LunarG packages on the test system showed that:

- `libvulkan1` owns only the loader runtime SONAME files
- `libvulkan-dev` owns the unversioned linker symlink, `vulkan.pc`, and
  `VulkanLoader` CMake files
- `vulkan-headers` owns the Vulkan headers and registry files

The local split now follows that structure rather than trying to replace all of
those identities from inside a single monolithic `vulkan-sdk` package.

### 3. `vulkan-sdk` in LunarG's apt repo is a meta-package, but this project keeps a payload-bearing `vulkan-sdk`

Inspecting LunarG's published `vulkan-sdk` package showed it contains only
package documentation and depends on many real component packages. This project
intentionally takes a simpler path for now:

- keep real packages for `libvulkan1`, `libvulkan-dev`, and `vulkan-headers`
- keep the remaining SDK payload bundled in one `vulkan-sdk` package

That reduces the amount of packaging work compared to a full distro-style split,
while still fixing the most important package-identity problem around
`libvulkan1`.

### 4. `vulkan-sdk` still overlaps many distro-owned tooling packages

The remaining SDK payload still overlaps files owned by packages such as:

- `slang`
- `spirv-headers`
- `spirv-cross-dev`
- `glslang-dev`
- `spirv-tools`
- `shaderc`
- `lunarg-gfxreconstruct`
- `vulkan-utility-libraries-dev`
- `vulkan-profiles`

This means the current split is a significant improvement, but not necessarily
the final package decomposition for a perfectly clean desktop install.

### 5. Reverse dependencies on `libvulkan1` do not require an exact version

The installed reverse dependencies of `libvulkan1` on the test system only used
minimum-version constraints, not exact-version constraints. Examples:

- `libgtk-4-1` → `libvulkan1 (>= 1.2.131.2)`
- `libgtk-4-bin` → `libvulkan1 (>= 1.2.131.2)`
- `libplacebo338` → `libvulkan1 (>= 1.2.131.2)`
- `libwebkitgtk-6.0-4` → `libvulkan1 (>= 1.2.131.2)`
- `mpv` → `libvulkan1 (>= 1.2.131.2)`
- `libvulkan-dev` → `libvulkan1 (>= 1.3.224.0~rc1)`
- `vulkan-tools` → `libvulkan1 (>= 1.3.231.0~rc1)`
- `vulkan-validationlayers` → `libvulkan1 (>= 1.3.243.0~rc1)`

This suggests that a loader version newer than those minimums (such as LunarG
`1.4.357`) is version-compatible from the dependency-metadata point of view.
The blocking issue was package identity and solver behavior, not the version.

### 6. Current conclusion

Breaking the SDK into at least these four packages is a much more credible
replacement strategy than a single monolithic `vulkan-sdk` package:

- `libvulkan1`
- `libvulkan-dev`
- `vulkan-headers`
- `vulkan-sdk`

However, `vulkan-sdk` still aggregates many components that also exist as
separate distro packages. If conflict pressure remains too high, the likely next
step is to split additional components out of `vulkan-sdk`, such as:

- `vulkan-tools`
- `vulkan-validationlayers`
- `spirv-tools`
- `shaderc`
- `glslang`
- `slang`
- `dxc`
- `lunarg-gfxreconstruct`

## How it works (in brief)

The LunarG tarball self-extracts to a leading `<version>/x86_64/{bin,include,lib,share}`
tree whose shipped binaries embed `RUNPATH=$ORIGIN/../lib` and whose layer
manifests use relative `library_path` paths — both resolve correctly only when
the SDK is rooted at `/usr`.

`build-deb.sh` therefore stages the SDK into four package roots:

- `libvulkan1` — loader runtime files
- `libvulkan-dev` — loader development links and metadata
- `vulkan-headers` — core headers and registry
- `vulkan-sdk` — the rest of the SDK tree, minus the files owned by the three
  core packages

The script then renders the templates in `control.d/` into package-specific
`DEBIAN/control` files and builds four `.deb` files.
