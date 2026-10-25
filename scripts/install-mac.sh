#!/usr/bin/env bash
#
# Installs the macOS port built by scripts/build-mac.sh over an existing Parallax Continued install.
# Replaces GameData/ParallaxContinued/Plugins/ParallaxContinued.dll and Shaders/Parallax*-macosx.unity3d,
# after backing them up to <KSP>/ParallaxMacPort-backups/<date> (outside GameData, so KSP doesn't load the old DLL).
#
# Usage: scripts/install-mac.sh [options]
#   --ksp DIR          KSP install folder (the one containing KSP.app and GameData)
#                      Default: ~/Library/Application Support/Steam/steamapps/common/Kerbal Space Program
#   --restore BACKUP   Put back the files from a backup folder instead of installing
#   -h, --help         Show this help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="$REPO_ROOT/build/GameData/ParallaxContinued"
KSP_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Kerbal Space Program"
RESTORE=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ksp) [ $# -ge 2 ] || die "--ksp needs a folder"; KSP_DIR="$2"; shift 2 ;;
        --restore) [ $# -ge 2 ] || die "--restore needs a backup folder"; RESTORE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

KSP_DIR="${KSP_DIR%/}"
GAMEDATA="$KSP_DIR/GameData"
TARGET="$GAMEDATA/ParallaxContinued"

[ -d "$GAMEDATA" ] || die "no GameData folder in '$KSP_DIR'. Pass the folder containing KSP.app with --ksp."
[ -f "$TARGET/Config/AssetBundleList.cfg" ] \
    || die "Parallax Continued isn't installed in '$GAMEDATA'. Install the official release and texture packs first (see README.md)."

# Copy every file in $1/<sub> into $2/<sub>
copy_files() {
    local from="$1" to="$2" sub file
    for sub in Plugins Shaders; do
        [ -d "$from/$sub" ] || continue
        mkdir -p "$to/$sub"
        for file in "$from/$sub"/*; do
            [ -f "$file" ] || continue
            cp -p "$file" "$to/$sub/"
            echo "    $sub/$(basename "$file")"
        done
    done
}

if [ -n "$RESTORE" ]; then
    [ -d "$RESTORE" ] || die "backup folder '$RESTORE' not found"
    log "Restoring $RESTORE into $TARGET"
    copy_files "$RESTORE" "$TARGET"
    exit 0
fi

has_plugin=0
has_shaders=0
[ -f "$STAGE_DIR/Plugins/ParallaxContinued.dll" ] && has_plugin=1
[ -f "$STAGE_DIR/Shaders/ParallaxScatters-macosx.unity3d" ] && has_shaders=1
if [ "$has_plugin" -eq 0 ] && [ "$has_shaders" -eq 0 ]; then
    die "nothing to install - run scripts/build-mac.sh first"
fi
# On OpenGL the CPU scatter backend and the texture instancing shaders only work together
if [ "$has_plugin" -eq 0 ]; then
    warn "only the shader bundles were built - scatters won't render on OpenGL until the patched plugin is installed too"
elif [ "$has_shaders" -eq 0 ]; then
    warn "only the plugin was built - scatters won't render on OpenGL until the macOS shader bundles are installed too"
fi

# Dependencies. KSP Burst only works on macOS from 1.7.4.11
for dep in "000_Harmony/0Harmony.dll:Harmony" "Kopernicus/Plugins/Kopernicus.dll:Kopernicus" \
           "000_KSPBurst/Plugins/KSPBurst.dll:KSP Burst" "KSPTextureLoader/Plugins/KSPTextureLoader.dll:KSPTextureLoader"; do
    [ -f "$GAMEDATA/${dep%%:*}" ] || warn "${dep#*:} doesn't seem to be installed (missing GameData/${dep%%:*})"
done
burst_version_file="$GAMEDATA/000_KSPBurst/KSPBurst.version"
if [ -f "$burst_version_file" ]; then
    burst_version="$(tr -d ' \n\r\t' < "$burst_version_file" | sed -n 's/.*"VERSION":{"MAJOR":\([0-9]*\),"MINOR":\([0-9]*\),"PATCH":\([0-9]*\),"BUILD":\([0-9]*\)}.*/\1 \2 \3 \4/p')"
    if [ -n "$burst_version" ]; then
        set -- $burst_version
        if [ "$1" -lt 1 ] || { [ "$1" -eq 1 ] && { [ "$2" -lt 7 ] || { [ "$2" -eq 7 ] && { [ "$3" -lt 4 ] || { [ "$3" -eq 4 ] && [ "$4" -lt 11 ]; }; }; }; }; }; then
            warn "KSP Burst $1.$2.$3.$4 is installed, but 1.7.4.11 or newer is needed on macOS"
        fi
    fi
fi

backup="$KSP_DIR/ParallaxMacPort-backups/$(date +%Y%m%d-%H%M%S)"
log "Backing up the files being replaced to $backup"
mkdir -p "$backup/Plugins" "$backup/Shaders"
if [ -f "$TARGET/Plugins/ParallaxContinued.dll" ]; then
    cp -p "$TARGET/Plugins/ParallaxContinued.dll" "$backup/Plugins/"
fi
for bundle in "$TARGET"/Shaders/*-macosx.unity3d; do
    if [ -f "$bundle" ]; then
        cp -p "$bundle" "$backup/Shaders/"
    fi
done

log "Installing into $TARGET"
copy_files "$STAGE_DIR" "$TARGET"

echo
echo "Done. Launch KSP normally - no launch options are needed."
echo "To undo: scripts/install-mac.sh --ksp \"$KSP_DIR\" --restore \"$backup\""
