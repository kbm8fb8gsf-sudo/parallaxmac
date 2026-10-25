#!/usr/bin/env bash
#
# Builds the macOS port of Parallax Continued:
#   build/GameData/ParallaxContinued/Plugins/ParallaxContinued.dll   (patched plugin)
#   build/GameData/ParallaxContinued/Shaders/Parallax*-macosx.unity3d (Metal + OpenGL shader bundles)
#
# Usage: scripts/build-mac.sh [options]
#   --ksp DIR        KSP install folder (the one containing KSP.app and GameData)
#                    Default: ~/Library/Application Support/Steam/steamapps/common/Kerbal Space Program
#   --unity PATH     Unity 2019.4.18f1 editor binary
#                    Default: /Applications/Unity/Hub/Editor/2019.4.18f1/Unity.app/Contents/MacOS/Unity
#   --skip-plugin    Don't build the plugin DLL
#   --skip-shaders   Don't build the shader bundles (needs no Unity install)
#   --install        Copy the result into KSP's GameData afterwards (see scripts/install-mac.sh)
#   -h, --help       Show this help
#
# Environment:
#   PARALLAX_UPSTREAM_URL     Upstream repository (default: Gameslinx/Parallax-Continued on GitHub)
#   PARALLAX_UPSTREAM_COMMIT  Upstream commit to build; the patches are made against the default
#
# Bash 3.2 compatible, as shipped with macOS.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

UPSTREAM_URL="${PARALLAX_UPSTREAM_URL:-https://github.com/Gameslinx/Parallax-Continued.git}"
# Parallax Continued master on 2026-10-20 (1.0.6 plus the Linux/OpenGL raymarched shadow fix)
UPSTREAM_COMMIT="${PARALLAX_UPSTREAM_COMMIT:-3cc1f83d6ac73c57c324852fadb9a59425e45005}"
UNITY_VERSION="2019.4.18f1"

KSP_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Kerbal Space Program"
UNITY="/Applications/Unity/Hub/Editor/$UNITY_VERSION/Unity.app/Contents/MacOS/Unity"
BUILD_PLUGIN=1
BUILD_SHADERS=1
INSTALL=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ksp) [ $# -ge 2 ] || die "--ksp needs a folder"; KSP_DIR="$2"; shift 2 ;;
        --unity) [ $# -ge 2 ] || die "--unity needs a path"; UNITY="$2"; shift 2 ;;
        --skip-plugin) BUILD_PLUGIN=0; shift ;;
        --skip-shaders) BUILD_SHADERS=0; shift ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

KSP_DIR="${KSP_DIR%/}"
UPSTREAM_DIR="$BUILD_DIR/upstream"
STAGE_DIR="$BUILD_DIR/GameData/ParallaxContinued"

#
#  Upstream source
#

fetch_upstream() {
    command -v git >/dev/null || die "git is required (xcode-select --install)"

    if [ ! -d "$UPSTREAM_DIR/.git" ]; then
        log "Cloning Parallax Continued source (code only - the texture history is several GB and isn't needed)"
        mkdir -p "$BUILD_DIR"
        git clone --filter=blob:none --no-checkout --sparse "$UPSTREAM_URL" "$UPSTREAM_DIR"
    fi

    git -C "$UPSTREAM_DIR" sparse-checkout set --no-cone "/Mod Source/Parallax/" "/Assets/Shaders/" "/ProjectSettings/"

    if ! git -C "$UPSTREAM_DIR" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
        log "Fetching upstream commit $UPSTREAM_COMMIT"
        git -C "$UPSTREAM_DIR" fetch --filter=blob:none origin "$UPSTREAM_COMMIT" \
            || git -C "$UPSTREAM_DIR" fetch --filter=blob:none origin
    fi

    log "Checking out upstream $UPSTREAM_COMMIT"
    git -C "$UPSTREAM_DIR" checkout --quiet --force --detach "$UPSTREAM_COMMIT"
    # Undo the patches and build output of a previous run
    git -C "$UPSTREAM_DIR" clean -fdxq

    log "Applying the macOS port patches"
    local patch
    for patch in "$REPO_ROOT"/patches/*.patch; do
        git -C "$UPSTREAM_DIR" apply --check "$patch" \
            || die "$(basename "$patch") doesn't apply to upstream $UPSTREAM_COMMIT. If you changed PARALLAX_UPSTREAM_COMMIT, the patches need updating."
        git -C "$UPSTREAM_DIR" apply "$patch"
        echo "    $(basename "$patch")"
    done
}

#
#  Plugin
#

check_ksp() {
    [ -d "$KSP_DIR" ] || die "KSP not found at '$KSP_DIR'. Pass the folder containing KSP.app with --ksp."
    [ -f "$KSP_DIR/KSP.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll" ] \
        || die "'$KSP_DIR' doesn't look like a macOS KSP install (no KSP.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll)"
}

check_dependency() {
    # $1 = name, $2 = path relative to GameData, $3 = where to get it
    [ -f "$KSP_DIR/GameData/$2" ] || die "$1 is not installed (missing GameData/$2). Install it first: $3"
}

build_plugin() {
    command -v dotnet >/dev/null || die "the .NET SDK is required to build the plugin: brew install --cask dotnet-sdk (or https://dotnet.microsoft.com/download)"
    local dotnet_major
    dotnet_major="$(dotnet --version | cut -d. -f1)"
    [ "$dotnet_major" -ge 8 ] 2>/dev/null || die ".NET SDK 8 or newer is required (found $(dotnet --version))"

    check_ksp
    check_dependency "Harmony" "000_Harmony/0Harmony.dll" "https://github.com/KSPModdingLibs/HarmonyKSP/releases"
    check_dependency "Kopernicus" "Kopernicus/Plugins/Kopernicus.dll" "https://github.com/Kopernicus/Kopernicus/releases"
    check_dependency "KSP Burst" "000_KSPBurst/Plugins/KSPBurst.dll" "https://github.com/KSPModdingLibs/KSPBurst/releases"
    check_dependency "KSPTextureLoader" "KSPTextureLoader/Plugins/KSPTextureLoader.dll" "https://github.com/Phantomical/KSPTextureLoader/releases"

    # Parallax.csproj expects a Windows install layout: GameData next to KSP_x64_Data/Managed.
    # Recreate that with links into the macOS install instead of editing the project.
    local refs="$BUILD_DIR/ksp-references"
    rm -rf "$refs"
    mkdir -p "$refs/GameData" "$refs/KSP_x64_Data"
    ln -s "$KSP_DIR/KSP.app/Contents/Resources/Data/Managed" "$refs/KSP_x64_Data/Managed"
    local dep
    for dep in 000_Harmony Kopernicus 000_KSPBurst KSPTextureLoader; do
        ln -s "$KSP_DIR/GameData/$dep" "$refs/GameData/$dep"
    done

    log "Building ParallaxContinued.dll"
    mkdir -p "$STAGE_DIR/Plugins"
    rm -f "$STAGE_DIR/Plugins/ParallaxContinued.dll" "$STAGE_DIR/Plugins/ParallaxContinued.pdb"
    # LangVersion: the project asks for C# 13, which needs .NET SDK 9. Nothing in it needs more than C# 12.
    dotnet build "$UPSTREAM_DIR/Mod Source/Parallax/Parallax.csproj" \
        --configuration Release \
        --nologo \
        "-p:GameDataPath=$refs/GameData/" \
        "-p:OutDir=$STAGE_DIR/Plugins/" \
        "-p:LangVersion=latest"

    [ -f "$STAGE_DIR/Plugins/ParallaxContinued.dll" ] || die "the build did not produce ParallaxContinued.dll"
    rm -f "$STAGE_DIR/Plugins/ParallaxContinued.pdb"
}

#
#  Shader bundles
#

build_shaders() {
    [ -x "$UNITY" ] || die "Unity $UNITY_VERSION not found at '$UNITY'.
    Install it from Unity Hub (open unityhub://$UNITY_VERSION/3310a4d4f880 in a browser, or use the Unity download archive),
    sign in to the Hub once so the free Personal licence is activated, or pass the editor binary with --unity.
    Or use --skip-shaders to only build the plugin."

    command -v rsync >/dev/null || die "rsync is required"

    local project="$BUILD_DIR/unity-project"
    log "Preparing the Unity project in $project"
    mkdir -p "$project/Assets" "$project/Packages" "$project/ProjectSettings"
    # Upstream's settings: gamma colour space and the same shader variant stripping as the official bundles
    rsync -a --delete "$UPSTREAM_DIR/ProjectSettings/" "$project/ProjectSettings/"
    rsync -a --delete "$REPO_ROOT/unity/ParallaxMacShaders/Assets/Editor/" "$project/Assets/Editor/"
    cp "$REPO_ROOT/unity/ParallaxMacShaders/Assets/Editor.meta" "$project/Assets/Editor.meta"
    cp "$REPO_ROOT/unity/ParallaxMacShaders/Packages/manifest.json" "$project/Packages/manifest.json"
    rm -f "$project/Packages/packages-lock.json"
    rsync -a --delete "$UPSTREAM_DIR/Assets/Shaders/" "$project/Assets/Shaders/"

    # Switch the OpenGL scatter shaders to texture instancing for this build only
    cat > "$project/Assets/Shaders/Scatters/InstancingShaders/ParallaxScatterPlatform.cginc" <<'EOF'
// Written by scripts/build-mac.sh - macOS OpenGL 4.1 has no structured buffers
#define PARALLAX_TEXTURE_INSTANCING_GLCORE
EOF

    mkdir -p "$STAGE_DIR/Shaders"
    rm -f "$STAGE_DIR"/Shaders/*-macosx.unity3d "$STAGE_DIR"/Shaders/*.manifest

    local unity_log="$BUILD_DIR/unity-build.log"
    log "Building the shader bundles with Unity $UNITY_VERSION"
    echo "    This compiles thousands of shader variants for Metal and OpenGL. The first build can take"
    echo "    a long time (expect tens of minutes); later builds reuse Unity's shader cache."
    echo "    Log: $unity_log"
    local status=0
    "$UNITY" -batchmode -nographics \
        -buildTarget OSXUniversal \
        -projectPath "$project" \
        -executeMethod ParallaxMacBundleBuilder.BuildFromCommandLine \
        -parallaxOutput "$STAGE_DIR/Shaders" \
        -logFile "$unity_log" || status=$?

    if [ "$status" -ne 0 ]; then
        tail -n 40 "$unity_log" >&2 || true
        if grep -qi "licen" "$unity_log" 2>/dev/null; then
            warn "Unity reported a licence problem - open Unity Hub, sign in and activate a free Personal licence, then retry"
        fi
        die "Unity exited with status $status (full log: $unity_log)"
    fi

    # The legacy bundle API also writes .manifest files, which KSP doesn't need
    rm -f "$STAGE_DIR"/Shaders/*.manifest

    local bundle
    for bundle in ParallaxTerrain ParallaxScaled ParallaxScatters ParallaxCompute ParallaxDebug; do
        [ -f "$STAGE_DIR/Shaders/$bundle-macosx.unity3d" ] || die "Unity did not produce $bundle-macosx.unity3d (see $unity_log)"
    done
}

#
#  Main
#

[ "$(uname -s)" = "Darwin" ] || warn "this script is meant to run on macOS"

fetch_upstream
if [ "$BUILD_PLUGIN" -eq 1 ]; then
    build_plugin
fi
if [ "$BUILD_SHADERS" -eq 1 ]; then
    build_shaders
fi

log "Built into $BUILD_DIR/GameData:"
(cd "$BUILD_DIR/GameData" && find . -type f | sed 's|^\./|    |' | sort)

if [ "$INSTALL" -eq 1 ]; then
    "$REPO_ROOT/scripts/install-mac.sh" --ksp "$KSP_DIR"
else
    echo
    echo "Install with: scripts/install-mac.sh --ksp \"$KSP_DIR\""
fi
