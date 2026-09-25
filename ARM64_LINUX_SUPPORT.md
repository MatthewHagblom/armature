# Armature: native AArch64 Linux support

Armature is an unofficial port of Blender to 64-bit Arm (AArch64) Linux, based on Blender's
open source code. Blender builds on AArch64 Linux, but the Blender project publishes neither
Linux AArch64 releases nor the precompiled libraries needed to build one. This repository adds
what is missing: a small set of source changes and a script that builds all the libraries and
the application from source in one go.

Armature is not affiliated with or endorsed by the Blender Foundation, and "Blender" is their
trademark. Please don't report problems with this port to the Blender project.

## How this port is made

**This is an LLM-powered port.** Its code changes, build script and documentation were written
by Claude, an AI model made by Anthropic, working in Claude Code. The repository owner set the
goals, tested the builds by hand and decided what to publish, but didn't write the changes or
review them line by line. Every change is built and tested on the system below before it is
published, and each commit names the model that made it in its `Patched-and-ported-by:` line.

The investigation behind each fix was done the same way. For example, the model traced invisible
instanced geometry in the CUDA viewport to a GCC 14 miscompilation, reproduced it in a small test
program and wrote the workaround; the repository owner found the symptom while testing by hand.

*Ported by Claude Opus 5.5 (Anthropic).*

## Branches

Each `arm64-linux-<version>` branch is an unmodified upstream Blender release tag (for example
`v5.2.2`) followed by the same port commits. The repository's default branch is the newest
one. `main` mirrors upstream Blender's `main` without changes.

## Tested system

| | |
| --- | --- |
| Machine | NVIDIA DGX Spark |
| CPU | NVIDIA GB10: 10× Arm Cortex-X925 (up to 3.9 GHz) and 10× Cortex-A725 (up to 2.8 GHz) |
| GPU | NVIDIA GB10 (Blackwell, compute capability 12.1) |
| Memory | 128 GB unified memory, shared by the CPU and GPU (121 GiB visible to Linux) |
| OS | DGX OS 7.2.3 (Ubuntu 24.04.4 LTS), kernel 6.17.0-1021-nvidia |
| Desktop | GNOME Shell 46 on X11 |
| NVIDIA driver | 580.159.03 (Vulkan 1.4.312) |
| CUDA toolkit | 12.8 (nvcc 12.8.93) for the build, next to the system's default 13.0 |
| OptiX | SDK headers 8.0.0, runtime from the driver |
| Compiler | GCC 14.2.0 (Ubuntu's `gcc-14` package) |
| Other tools | CMake 3.28.3, Ninja 1.11.1, glibc 2.39 |

## Status

Results on the tested system:

| Feature | Status |
| --- | --- |
| Building the libraries and Blender with the script | Works |
| Cycles on the CPU | Works |
| Cycles with CUDA | Works. GB10 runs the prebuilt Blackwell (`sm_120`) kernels |
| Cycles with OptiX | Works |
| OSL shaders in Cycles with OptiX | Works. The first render compiles GPU code for about 6 minutes, later renders use the driver's cache |
| OpenImageDenoise | Works on the CPU and on the GPU (CUDA) |
| EEVEE with OpenGL | Works, including background rendering without a display (EGL) |
| EEVEE with Vulkan | Works |
| Interactive use | Works: the viewport with Workbench, EEVEE and Cycles (CPU, CUDA and OptiX), the OpenGL and Vulkan backends, and saving and loading files |
| AMD HIP and Intel oneAPI | Not available: their toolchains don't support AArch64 Linux |

Cycles logs `HIPEW initialization failed` at startup. That is expected and harmless: it
looks for AMD's HIP runtime, which doesn't exist on this platform.

## Building

```sh
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/MatthewHagblom/armature.git
cd armature
./build_linux_arm64.sh
```

The finished build is `build/blender/bin/blender`. The `build/blender/bin` directory contains
everything it needs except the C and C++ runtime, X11 and OpenGL libraries of the system (the
`verify` step checks this), so it can be moved or copied to another AArch64 Linux machine with an
NVIDIA driver and a glibc at least as new as the build system's.

`GIT_LFS_SKIP_SMUDGE=1` is needed because Blender stores images, `.blend` files and other
binary files with Git LFS, and those files are not available from GitHub. The script fetches
them from projects.blender.org instead, the same way Blender's `make update` does for forks.

### Requirements

- AArch64 Linux. The script is tested on Ubuntu 24.04 and checks for the packages it needs
  there. Other distributions need the equivalent packages.
- The Ubuntu packages listed in `APT_PACKAGES` at the top of the script. If any are missing, the
  script stops and prints the `sudo apt install` command for them. It never runs `sudo` itself.
- The NVIDIA CUDA toolkit version that official Blender releases are built with (for example 12.8,
  see `RELEASE_CUDA_VERSION` in `build_files/build_environment/cmake/versions.cmake`),
  installed in `/usr/local/cuda-<version>`. It can sit next to other versions: DGX OS ships CUDA
  13.0, which stays the system default, and the script only uses the release version for its
  own build. Newer toolkits don't work for every dependency. For example, CUDA 13 removed headers
  that LLVM 20's Clang needs to compile OSL's GPU code. The script tells you the `apt` command
  when the version is missing.
- About 30 GB of free disk space. On the tested system the first build takes about an hour:
  5 minutes for the Git LFS files, 45 minutes for the libraries and 13 minutes for Blender.
  Later runs only rebuild what changed.
- A checkout path without spaces, which several dependency builds don't support.

### What the script does

| Step | What it does |
| --- | --- |
| `prereqs` | Checks the platform, packages, GCC 14 and the CUDA toolkit. |
| `lfs` | Fetches missing Git LFS files from projects.blender.org. |
| `optix` | Downloads the OptiX SDK headers from [NVIDIA's GitHub](https://github.com/NVIDIA/optix-dev) into `build/`, using the version official releases use (`build_files/config/pipeline_config.yaml`). |
| `deps` | Runs Blender's `make deps`, which downloads the source of every library from its upstream project and builds it into `lib/linux_arm64/`. |
| `blender` | Runs `make release` with GCC 14, the release CUDA version and the OptiX headers, into `build/blender/`. |
| `verify` | Checks the binary is AArch64, finds all its libraries and doesn't depend on unexpected system libraries, and that Cycles finds the CUDA and OptiX devices. |
| `smoke` | Renders the default scene plus an instanced copy of the cube with Cycles on the CPU, CUDA and OptiX, into `build/smoke/`, and fails if a GPU render differs from the CPU render. |
| `desktop` | Optional, only runs when asked for (`--only desktop`). Adds the build to the desktop's applications menu as `Armature <version>` and opens `.blend` files with it. |

Every step can be re-run on its own, for example `./build_linux_arm64.sh --only blender,verify`.
Re-runs are incremental. Logs go to `build/logs/`. Run `./build_linux_arm64.sh --help` for all
options, including `--no-optix` to build without OptiX (CUDA rendering still works).

## Changes from upstream Blender

All changes to upstream files are small. Only one touches Blender's source code, working around a
compiler bug; the others are build configuration. Most of them adapt Blender's library build to Ubuntu, because upstream builds its Linux libraries
on Rocky Linux 8.

| File | Change |
| --- | --- |
| `build_files/cmake/config/blender_release.cmake` | The release configuration doesn't enable AMD HIP, HIP RT and Intel oneAPI on Linux AArch64, where their toolchains don't exist. CUDA and OptiX stay enabled. |
| `build_files/build_environment/linux/make_deps_wrapper.sh` | Fixes every library building on a single core when `make deps` is given variables such as `BUILD_DIR=...`: the wrapper appended its `-j` option after `--` in `MAKEFLAGS`, where `make` ignores it. This affects all Linux systems, not only AArch64. |
| `build_files/build_environment/cmake/wayland.cmake` | Installs Wayland's libraries into `lib64`, where the rest of the library build expects them. Meson's default on Debian and Ubuntu is `lib/aarch64-linux-gnu`. |
| `build_files/build_environment/cmake/ffmpeg.cmake` | Disables FFmpeg's `libdrm` support, which FFmpeg enables automatically when the system has `libdrm` development files. Blender doesn't link `libdrm`, so linking failed. |
| `build_files/build_environment/cmake/ceres.cmake` | Stops Ceres from linking the system's BLAS/LAPACK (OpenBLAS) and SuiteSparse, which would make the build depend on them at run-time. |
| `intern/cycles/util/types_{float3,float4,int3,int4}.h` | Works around a GCC 14 bug on AArch64 that made instanced geometry invisible in Cycles on CUDA (and on the CPU with the BVH2 layout), which includes everything in the viewport. GCC 14.2 at `-O2` drops vector components when these types are copied through their hand-written assignment operator; GCC 13 and Clang don't. The operators are now defaulted, which means the same on every platform. |
| `.gitignore` | Ignores `lib/linux_arm64/`, where the libraries are built. |
| `build_linux_arm64.sh`, `ARM64_LINUX_SUPPORT.md`, `README.md` | The build script and this documentation. |
| `.github/README.md` | Removed. GitHub shows it instead of `README.md`, and upstream's copy describes Blender's GitHub mirror. |

Official Blender releases already handle the rest: Cycles skips CUDA architectures a toolkit
doesn't support, the library build targets AArch64 (`-march=armv8.2-a+dotprod+fp16+lse`), and
Embree, OpenImageDenoise and ISPC have AArch64 support.

## Licensing

- Blender and this port are licensed under the GNU GPL. See `COPYING` and
  [blender.org/about/license](https://www.blender.org/about/license).
- This repository contains no third-party binaries. `make deps` downloads each library's source
  from its upstream project and builds it locally, and each library keeps its own license.
- The OptiX headers are downloaded from NVIDIA by the script and are covered by NVIDIA's
  license (`build/optix-<version>/LICENSE.txt`). They are not part of this repository. Use
  `--no-optix` if you don't want them.
- The CUDA toolkit comes from NVIDIA and is not part of this repository.
- Builds keep Blender's name and logo, because the port doesn't change upstream branding. If
  you share builds, the GPL requires you to also offer their source code, and Blender's
  [trademark policy](https://www.blender.org/about/trademark-policy/) means you must not
  present them as Blender.

## Maintaining the port

The repository uses two remotes: `origin` is this GitHub repository and `upstream` is
`https://projects.blender.org/blender/blender.git`.

To port a new Blender release, create a branch from its tag, cherry-pick the port commits from
the previous branch, then build and test it:

```sh
git fetch upstream --tags
git worktree add -b arm64-linux-<new> ../<new-worktree> v<new>
cd ../<new-worktree>
git cherry-pick -x v<old>..arm64-linux-<old>
./build_linux_arm64.sh
git push --no-verify -u origin arm64-linux-<new>
```

A fix goes onto every branch it applies to as its own commit. After publishing a new branch,
make it the default branch on GitHub.

Always push with `--no-verify`. Without it, Git LFS's `pre-push` hook tries to upload LFS files
to GitHub, which is not where this repository keeps them.
