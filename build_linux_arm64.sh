#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Armature Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Build Armature (a native AArch64 Linux port based on Blender's source code) in one go:
# check prerequisites, fetch Git LFS files and OptiX headers, build the library dependencies
# from source (`make deps`), build the release configuration, then verify and smoke test it.
#
# Everything is built inside this checkout: `build/` (ignored by Git) and `lib/linux_arm64/`.
# See ARM64_LINUX_SUPPORT.md for details.
#
# Written by Claude Opus 5.5, an AI model made by Anthropic, for the Armature port.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_ROOT=$ROOT/build
LOG_DIR=$BUILD_ROOT/logs
BLENDER_BUILD_DIR=$BUILD_ROOT/blender
BLENDER_BIN=$BLENDER_BUILD_DIR/bin/blender
DEPS_DIR=$ROOT/lib/linux_arm64

# Official releases are built with GCC 14.2, see `RELEASE_GCC_VERSION` in
# `build_files/build_environment/cmake/versions.cmake`.
export CC=gcc-14
export CXX=g++-14

# Use the CUDA toolkit version official releases are built with (`RELEASE_CUDA_VERSION`), it can be
# installed next to the system's default one. Newer versions break parts of the build, for example
# CUDA 13 removed headers that LLVM 20's Clang needs to compile OSL's GPU code.
CUDA_VERSION=$(awk -F'[ )]' '/^set\(RELEASE_CUDA_VERSION /{ print $2 }' \
  "$ROOT/build_files/build_environment/cmake/versions.cmake")
CUDA_ROOT=/usr/local/cuda-$CUDA_VERSION
export PATH=$CUDA_ROOT/bin:$PATH
# Found by CMake's `FindCUDAToolkit` (dependencies) and `FindCUDA` (Cycles).
export CUDAToolkit_ROOT=$CUDA_ROOT
export CUDA_PATH=$CUDA_ROOT

# `nproc` reports these limits instead of the CPU count. Some environments (editors, job
# schedulers) set `OMP_NUM_THREADS=1`, which would silently make the whole build single-threaded.
unset OMP_NUM_THREADS OMP_THREAD_LIMIT

# Ubuntu 24.04 packages, mapped from `build_files/build_environment/linux/linux_rocky8_setup.sh`.
APT_PACKAGES=(
  build-essential gcc-14 g++-14 cmake ninja-build git git-lfs curl file patch patchelf
  autoconf automake autogen autopoint libtool libtool-bin help2man gettext texinfo asciidoctor
  bison flex tcl yasm perl bzip2 tar wget zlib1g-dev libncurses-dev libffi-dev
  python3 python3-dev python3-pip python3-mako python3-yaml
  libegl-dev libgl-dev libglu1-mesa-dev libgbm-dev libdrm-dev libcairo2-dev libpixman-1-dev
  libinput-dev libevdev-dev libudev-dev
  libx11-dev libx11-xcb-dev libxcursor-dev libxi-dev libxinerama-dev libxrandr-dev libxt-dev
  libxxf86vm-dev libxkbcommon-dev
  libasound2-dev libpulse-dev libjack-jackd2-dev
)

ALL_STEPS=(prereqs lfs optix deps blender verify smoke)
# Only run when asked for with `--only`.
OPTIONAL_STEPS=(desktop)
STEPS=("${ALL_STEPS[@]}")
JOBS=$(nproc)
WITH_OPTIX=1

usage() {
  cat <<EOF
Usage: ./build_linux_arm64.sh [options]

Builds everything in one go. The first run takes about an hour on an NVIDIA DGX Spark (20 cores),
mostly for \`make deps\`. Re-running is incremental.

Options:
  --only STEP[,STEP...]  Run only these steps, in order: ${ALL_STEPS[*]}
                         Optional step, only run when listed here:
                           desktop  Add the build to the desktop's applications menu
  --jobs N               Parallel jobs (default: $JOBS)
  --no-optix             Build without OptiX, skipping the NVIDIA OptiX header download
  -h, --help             Show this help
EOF
}

while (($#)); do
  case $1 in
    --only)
      [[ ${2:-} ]] || { usage >&2; exit 2; }
      IFS=, read -r -a STEPS <<< "$2"
      shift 2
      ;;
    --jobs)
      [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --no-optix) WITH_OPTIX=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
for step in "${STEPS[@]}"; do
  [[ " ${ALL_STEPS[*]} ${OPTIONAL_STEPS[*]} " == *" $step "* ]] ||
    { echo "Unknown step: $step" >&2; exit 2; }
done

log() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Run a command with its output going to `build/logs/<name>.log`, show the end of it on failure.
run_logged() {
  local name=$1
  shift
  mkdir -p "$LOG_DIR"
  note "log: build/logs/$name.log"
  if ! "$@" > "$LOG_DIR/$name.log" 2>&1; then
    tail -n 40 "$LOG_DIR/$name.log" >&2
    die "step '$name' failed, see build/logs/$name.log"
  fi
}

optix_version() {
  # The OptiX SDK version used for official releases.
  awk '/^ *optix:/ { found = 1; next } found && /version:/ { gsub(/[^0-9.]/, "", $2); print $2; exit }' \
    "$ROOT/build_files/config/pipeline_config.yaml"
}

step_prereqs() {
  log "Checking prerequisites"
  [[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] ||
    die "this script builds natively on AArch64 Linux only (this is $(uname -s) $(uname -m))"
  [[ $ROOT != *[[:space:]]* ]] ||
    die "the checkout path contains whitespace, which breaks several dependency builds: $ROOT"

  if command -v dpkg-query > /dev/null; then
    local missing=() package
    for package in "${APT_PACKAGES[@]}"; do
      dpkg-query -W -f='${Status}' "$package" 2> /dev/null | grep -q 'install ok installed' ||
        missing+=("$package")
    done
    ((${#missing[@]} == 0)) ||
      die "missing packages, install them with:"$'\n\n'"  sudo apt install ${missing[*]}"
  else
    note "not a Debian or Ubuntu system, skipping the package check (see ARM64_LINUX_SUPPORT.md)"
  fi

  local tool
  for tool in "$CC" "$CXX" cmake ninja git git-lfs curl patch make python3; do
    command -v "$tool" > /dev/null || die "'$tool' not found"
  done
  [[ $CUDA_VERSION ]] ||
    die "could not read RELEASE_CUDA_VERSION from build_files/build_environment/cmake/versions.cmake"
  [[ -x $CUDA_ROOT/bin/nvcc ]] ||
    die "CUDA $CUDA_VERSION (the version official releases use) was not found in $CUDA_ROOT.
With NVIDIA's CUDA repository set up (DGX OS has it), install it next to other versions with:

  sudo apt install cuda-toolkit-${CUDA_VERSION/./-}"

  note "$(uname -sr), $("$CC" --version | head -n 1)"
  note "CUDA $("$CUDA_ROOT/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\),.*/\1/p') ($CUDA_ROOT)"
  if command -v nvidia-smi > /dev/null; then
    note "GPU: $(nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader 2> /dev/null |
      head -n 1)"
  fi
}

step_lfs() {
  log "Checking Git LFS files"
  # Same as `make update`: set up the LFS filters without installing hooks.
  git -C "$ROOT" lfs install --skip-repo > /dev/null
  local missing
  missing=$(git -C "$ROOT" lfs ls-files | awk '$2 == "-"' | wc -l)
  if ((missing == 0)); then
    note "all LFS files are present"
    return
  fi
  # Forks hosted outside projects.blender.org (like this one on GitHub) don't carry the LFS
  # files, so fetch them from upstream, using the same remote name as `make update`.
  local remote
  remote=$(git -C "$ROOT" remote -v |
    awk '$2 ~ /^https:\/\/projects\.blender\.org\/blender\/blender(\.git)?$/ && $3 == "(fetch)" { print $1; exit }')
  if [[ -z $remote ]]; then
    remote=lfs-fallback
    git -C "$ROOT" remote add "$remote" https://projects.blender.org/blender/blender.git
    git -C "$ROOT" remote set-url --push "$remote" no_push
  fi
  note "fetching $missing LFS files from projects.blender.org (remote '$remote')"
  run_logged lfs git -C "$ROOT" lfs pull "$remote"
}

step_optix() {
  if ((!WITH_OPTIX)); then
    log "Skipping OptiX headers (--no-optix)"
    return
  fi
  local version dir
  version=$(optix_version)
  [[ $version ]] || die "could not read the OptiX version from build_files/config/pipeline_config.yaml"
  dir=$BUILD_ROOT/optix-$version
  log "OptiX $version headers"
  if [[ ! -f $dir/include/optix.h ]]; then
    note "downloading from https://github.com/NVIDIA/optix-dev (tag v$version)"
    note "the headers are covered by NVIDIA's license, see $dir/LICENSE.txt"
    rm -rf "$dir.tmp"
    mkdir -p "$dir.tmp"
    curl -fsSL "https://github.com/NVIDIA/optix-dev/archive/refs/tags/v$version.tar.gz" |
      tar -xz -C "$dir.tmp" --strip-components=1
    mv "$dir.tmp" "$dir"
  fi
  local expected actual
  expected=$(awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }' <<< "$version")
  actual=$(awk '/^#define OPTIX_VERSION / { print $3 }' "$dir/include/optix.h")
  [[ $actual == "$expected" ]] || die "$dir/include/optix.h has OPTIX_VERSION $actual, expected $expected"
  note "$dir"
}

step_deps() {
  log "Building the library dependencies into lib/linux_arm64 (the longest step on the first run)"
  note "follow progress with: tail -f build/logs/deps.log"
  run_logged deps make -C "$ROOT" deps BUILD_DIR="$BUILD_ROOT" NPROCS="$JOBS"
}

step_blender() {
  [[ -d $DEPS_DIR ]] || die "lib/linux_arm64 not found, run the deps step first"
  local cmake_args
  if ((WITH_OPTIX)); then
    cmake_args="-DOPTIX_ROOT_DIR=$BUILD_ROOT/optix-$(optix_version)"
  else
    cmake_args="-DWITH_CYCLES_DEVICE_OPTIX=OFF"
  fi
  log "Building the release configuration"
  note "follow progress with: tail -f build/logs/blender.log"
  run_logged blender make -C "$ROOT" release ninja \
    BUILD_DIR="$BLENDER_BUILD_DIR" NPROCS="$JOBS" BUILD_CMAKE_ARGS="$cmake_args"
  note "$BLENDER_BIN"
}

# Print the Cycles GPU backends and devices, fail when an expected backend is missing.
PY_DEVICES='
import os, sys, _cycles
names = ("CUDA", "OPTIX", "HIP", "METAL", "ONEAPI", "HIPRT")
available = [name for name, ok in zip(names, _cycles.get_device_types()) if ok]
print("Cycles GPU backends:", ", ".join(available) or "none")
missing = []
for kind in os.environ["EXPECT_DEVICES"].split():
    devices = [d[0] for d in _cycles.available_devices(kind) if d[1] == kind]
    print(f"{kind} devices:", ", ".join(devices) or "none")
    if not devices:
        missing.append(kind)
if missing:
    sys.exit("no " + " or ".join(missing) + " device found")
'

expected_devices() {
  if nvidia-smi -L > /dev/null 2>&1; then
    printf 'CUDA'
    ((WITH_OPTIX)) && printf ' OPTIX'
  fi
  return 0
}

step_verify() {
  log "Verifying the build"
  [[ -x $BLENDER_BIN ]] || die "$BLENDER_BIN not found, run the blender step first"
  file -L "$BLENDER_BIN" | grep -q 'ARM aarch64' || die "$BLENDER_BIN is not an AArch64 executable"
  if ldd "$BLENDER_BIN" | grep 'not found'; then
    die "$BLENDER_BIN has unresolved shared libraries"
  fi
  # Everything else ships in `bin/lib`, a library found on the build system (like Ceres picking up
  # the system's OpenBLAS) would make the build depend on packages other systems may not have.
  local unexpected
  unexpected=$(ldd "$BLENDER_BIN" | awk -v bin="${BLENDER_BUILD_DIR}/bin/" '$3 != "" && index($3, bin) != 1 { print $1 }' |
    grep -vE '^(ld-linux-aarch64|libc|libm|libmvec|libstdc\+\+|libgcc_s|libGL|libGLX|libGLdispatch|libX11|libXext|libXfixes|libXi|libxkbcommon|libxcb|libXau|libXdmcp|libbsd|libmd)\.so' || true)
  [[ -z $unexpected ]] || die "$BLENDER_BIN depends on unexpected system libraries: $(echo $unexpected)"
  note "$("$BLENDER_BIN" --version | head -n 1)"
  local output status=0
  output=$(EXPECT_DEVICES=$(expected_devices) "$BLENDER_BIN" -b --factory-startup \
    --python-exit-code 1 --python-expr "$PY_DEVICES" 2>&1) || status=$?
  grep -E '^(Cycles GPU backends|[A-Z]+ devices|Error|no )' <<< "$output" | sed 's/^/    /' || true
  ((status == 0)) || die "Cycles device check failed"
}

# Render the default scene with Cycles on one device: `-- DEVICE OUTPUT`. A linked duplicate of the
# cube makes Cycles trace an instance, the case a miscompiled BVH once made invisible on CUDA.
PY_RENDER='
import sys, bpy
device, output = sys.argv[sys.argv.index("--") + 1:]
scene = bpy.context.scene
cube = bpy.data.objects["Cube"]
instance = cube.copy()
instance.location.x += 2.5
scene.collection.objects.link(instance)
scene.render.engine = "CYCLES"
scene.render.resolution_x, scene.render.resolution_y = 320, 240
scene.render.resolution_percentage = 100
scene.cycles.samples = 16
if device != "CPU":
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = device
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == device
    if not any(d.use for d in prefs.devices):
        sys.exit(f"no {device} device found")
    scene.cycles.device = "GPU"
scene.render.filepath = output
bpy.ops.render.render(write_still=True)
'

# Compare a render with the CPU reference: `-- REFERENCE IMAGE`. Matching renders differ by a mean
# of about 0.0001, a render missing the cubes by about 0.05.
PY_COMPARE='
import sys, bpy, numpy as np
reference, image = sys.argv[sys.argv.index("--") + 1:]
def pixels(path):
    loaded = bpy.data.images.load(path)
    values = np.empty(len(loaded.pixels), dtype=np.float32)
    loaded.pixels.foreach_get(values)
    return values.reshape(-1, 4)[:, :3]
difference = float(np.abs(pixels(reference) - pixels(image)).mean())
print(f"mean difference {difference:.4f}")
sys.exit(1 if difference > 0.01 else 0)
'

step_smoke() {
  log "Smoke test: headless Cycles renders, compared with the CPU render"
  [[ -x $BLENDER_BIN ]] || die "$BLENDER_BIN not found, run the blender step first"
  mkdir -p "$BUILD_ROOT/smoke"
  local device output reference=$BUILD_ROOT/smoke/cycles-cpu.png difference
  for device in CPU $(expected_devices); do
    output=$BUILD_ROOT/smoke/cycles-${device,,}.png
    rm -f "$output"
    run_logged "smoke-${device,,}" "$BLENDER_BIN" -b --factory-startup --python-exit-code 1 \
      --python-expr "$PY_RENDER" -- "$device" "$output"
    [[ -s $output ]] || die "the $device render produced no image"
    if [[ $device == CPU ]]; then
      note "$device: build/smoke/${output##*/}"
      continue
    fi
    run_logged "compare-${device,,}" "$BLENDER_BIN" -b --factory-startup --python-exit-code 1 \
      --python-expr "$PY_COMPARE" -- "$reference" "$output"
    difference=$(grep -oE 'mean difference [0-9.]+' "$LOG_DIR/compare-${device,,}.log")
    note "$device: build/smoke/${output##*/}, $difference from the CPU render"
  done
}

step_desktop() {
  log "Adding the build to the applications menu"
  [[ -x $BLENDER_BIN ]] || die "$BLENDER_BIN not found, run the blender step first"
  local version branch dir file
  version=$("$BLENDER_BIN" --version | sed -n '1s/^Blender \([0-9.]*\).*/\1/p')
  [[ $version ]] || die "could not read the version from $BLENDER_BIN --version"
  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  dir=${XDG_DATA_HOME:-$HOME/.local/share}
  # Terminals inside snap packaged applications (VSCodium, for example) inherit the snap's private
  # `XDG_DATA_HOME`, which the desktop doesn't read.
  if [[ ${SNAP_USER_DATA:-} && $dir == "$SNAP_USER_DATA"/* ]]; then
    dir=${SNAP_REAL_HOME:-$HOME}/.local/share
  fi
  dir=$dir/applications
  # One entry per version, so builds of several releases can be installed side by side.
  file=$dir/armature-$version.desktop
  mkdir -p "$dir"
  # Based on `release/freedesktop/blender.desktop`. The name isn't "Blender": this is an
  # unofficial modified build, but searching the menu for "blender" still finds it.
  cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=Armature $version
GenericName=3D modeler
Comment=Based on Blender $version, native AArch64 Linux build ($branch)
Keywords=blender;3d;cg;modeling;animation;painting;sculpting;texturing;rendering;cycles;
Exec=$BLENDER_BIN %f
Icon=$BLENDER_BUILD_DIR/bin/blender.svg
Terminal=false
PrefersNonDefaultGPU=true
Categories=Graphics;3DGraphics;
MimeType=application/x-blender;
StartupWMClass=Blender
EOF
  if command -v desktop-file-validate > /dev/null; then
    desktop-file-validate "$file" || die "$file is not a valid desktop entry"
  fi
  # Refresh the `.blend` file association.
  if command -v update-desktop-database > /dev/null; then
    update-desktop-database "$dir"
  fi
  note "$file"
  note "remove that file to take it off the menu again"
}

for step in "${STEPS[@]}"; do
  start=$SECONDS
  "step_$step"
  note "($step: $(((SECONDS - start) / 60))m $(((SECONDS - start) % 60))s)"
done
log "Done"
