#!/usr/bin/env bash
#
# Runs the CPU scatter backend's maths checks. Needs the .NET SDK and a patched upstream checkout from
# scripts/build-mac.sh (use --skip-plugin --skip-shaders to only fetch and patch it).
#
# Usage: tests/run-tests.sh [--ksp DIR]   (Unity.Mathematics.dll is taken from KSP Burst in DIR/GameData)
#        tests/run-tests.sh --mathematics PATH/TO/Unity.Mathematics.dll

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSP_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Kerbal Space Program"
MATHEMATICS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ksp) KSP_DIR="$2"; shift 2 ;;
        --mathematics) MATHEMATICS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$MATHEMATICS" ] || MATHEMATICS="${KSP_DIR%/}/GameData/000_KSPBurst/Plugins/Unity.Mathematics.dll"
SOURCE="$REPO_ROOT/build/upstream/Mod Source/Parallax"

[ -f "$MATHEMATICS" ] || { echo "Unity.Mathematics.dll not found at '$MATHEMATICS' (pass --ksp or --mathematics)" >&2; exit 1; }
[ -f "$SOURCE/Scatter System/CPU/CpuScatterMath.cs" ] || { echo "No patched source - run scripts/build-mac.sh first" >&2; exit 1; }

dotnet run --project "$REPO_ROOT/tests/cpu-scatter-math/CpuScatterMathTests.csproj" -c Release \
    "-p:ParallaxSource=$SOURCE" "-p:UnityMathematicsDll=$MATHEMATICS"
