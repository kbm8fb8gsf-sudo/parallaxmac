# Parallax Continued for macOS

A native macOS port of [Parallax Continued](https://github.com/Gameslinx/Parallax-Continued), the terrain
tessellation and surface scatter mod for Kerbal Space Program 1.12.5, aimed at Apple Silicon Macs
(written for an M1 Pro MacBook Pro). It runs in KSP's own macOS build, without CrossOver, Whisky or Wine.

> **Status: untested in game.** Everything here was written and checked without a Mac: the plugin compiles
> against KSP 1.12 reference assemblies, the patches apply to upstream, the build and install scripts run, and
> the CPU scatter maths matches the shader maths in automated checks. Nobody has launched KSP with it yet, and
> the macOS shader bundles have not been built yet (that needs Unity on your Mac, see below). Expect to find
> bugs on first launch. `KSP.log` is the place to look.

## Why Parallax doesn't run on macOS

KSP's macOS build renders with OpenGL by default, and macOS's OpenGL stops at **4.1**. Parallax's own startup
check says so: *"Parallax is not supported on MacOSX systems running OpenGL"*. It uses two things that need
OpenGL 4.3 or later:

* **compute shaders**, which place every rock, tree and blade of grass (`TerrainScatters.compute`), and
* **structured buffers**, which the scatter shaders read their per-object transforms from.

Everything else already works on OpenGL 4.1. The terrain and scaled-space shaders, including tessellation,
compile to GLSL 4.10 in the official macOS shader bundles. That's why upstream recommends running the Windows
build through CrossOver with D3DMetal.

## What the port changes

| Area | Change |
| --- | --- |
| Scatter placement | When the graphics API has no compute shaders, the `Distribute` and `Evaluate` kernels run as **Burst jobs** on the CPU instead (`Scatter System/CPU/`). The noise functions and placement rules are straight ports of the shader code. Per-object maths that doesn't change between frames is done once, when a quad is built. |
| Scatter rendering | The CPU results are uploaded to float textures (4 texels per object) and drawn with `Graphics.DrawMeshInstancedProcedural`. In the macOS bundle, the OpenGL variants of the scatter shaders read from that texture instead of a structured buffer. The per-LOD object caps are the same as the GPU path's. |
| Colliders | Positions come straight from the distribution job instead of a GPU readback. |
| Biome and block maps | Read from KSP's map data, since KSP and Kopernicus compile them to unreadable textures. |
| Messages | The "Parallax is not supported on MacOSX systems running OpenGL" popup is gone. The log says which scatter backend is in use. |
| Bug fix | `_WorldSpaceReferencePosition` was declared as a `float` in the compute shader, so scatters culled around the craft instead of the camera only got the x coordinate. The CPU backend doesn't have the bug. The shader fix only takes effect in bundles built from these patches. |

When compute shaders are available, the original GPU code path runs unchanged. That covers Windows, Linux,
CrossOver, and KSP on macOS launched with `-force-metal` (or `-force-gfx-metal`, as the KSP wiki spells it).
Metal has compute shaders, and the macOS bundle includes Metal programs. The Metal route is untested and may
not work at all, because KSP's own shaders may not include Metal versions. The OpenGL default is the
supported route.

The changes are kept as patches against a pinned upstream commit (`patches/`), and the build script applies
them to a fresh checkout. This repository doesn't redistribute Parallax itself.

## What you need

On the Mac:

* **KSP 1.12.5** (Steam or standalone). It's an Intel app, so Rosetta 2 must be installed.
* The mods Parallax depends on, installed in `GameData`:
  * [Kopernicus](https://github.com/Kopernicus/Kopernicus/releases), with the Module Manager it ships with
  * [KSP Burst](https://github.com/KSPModdingLibs/KSPBurst/releases) **1.7.4.11 or newer**. Earlier versions don't work on macOS.
  * [Harmony](https://github.com/KSPModdingLibs/HarmonyKSP/releases) (KSP Burst needs it)
  * [KSPTextureLoader](https://github.com/Phantomical/KSPTextureLoader/releases)
* **Parallax Continued 1.0.6** from the [upstream releases](https://github.com/Gameslinx/Parallax-Continued/releases),
  installed exactly as the upstream README describes for Windows: `ParallaxContinued.zip`, plus the stock terrain,
  scatter and planet texture packs. The port only replaces the plugin DLL and the macOS shader bundles. The
  configs, textures and models come from the official release.

To build the port:

* **git**: `xcode-select --install`
* **.NET SDK 8 or newer**: `brew install --cask dotnet-sdk`, or the installer from
  [dotnet.microsoft.com](https://dotnet.microsoft.com/download)
* **Unity 2019.4.18f1**, the same version KSP uses, for the shader bundles:
  1. Install [Unity Hub](https://unity.com/download) and sign in. This activates the free Personal licence,
     which Unity needs even in batch mode.
  2. Open `unityhub://2019.4.18f1/3310a4d4f880` in Safari to install that exact version. No extra modules are
     needed. 2019.4 is Intel-only and runs under Rosetta.

## Build and install

```bash
git clone https://github.com/kbm8fb8gsf-sudo/parallaxmac.git
cd parallaxmac
scripts/build-mac.sh --install
```

If KSP isn't in the default Steam location (`~/Library/Application Support/Steam/steamapps/common/Kerbal Space Program`),
pass `--ksp "/path/to/the folder containing KSP.app"` to both scripts.

What the build does:

1. Clones the upstream source into `build/upstream`, code only (the full repository is several GB of
   textures), checks out the pinned commit and applies `patches/`.
2. Builds `ParallaxContinued.dll` against your KSP install and mods.
3. Builds the five `Parallax*-macosx.unity3d` shader bundles with Unity in batch mode, for Metal and OpenGL
   Core. **The first run compiles thousands of shader variants and can take a long time.** Later runs reuse
   Unity's cache. The full log is in `build/unity-build.log`.
4. With `--install`, `scripts/install-mac.sh` backs up the files it replaces to
   `<KSP folder>/ParallaxMacPort-backups/<date>/` (outside GameData, so KSP doesn't load the old DLL) and
   copies the new ones into `GameData/ParallaxContinued`.

Useful options: `--skip-shaders` builds only the plugin (no Unity needed), and `--skip-plugin` builds only the
bundles. To undo the install, run
`scripts/install-mac.sh --restore "<KSP folder>/ParallaxMacPort-backups/<date>"`.

Then launch KSP normally, without launch options. As the upstream README says, set *Settings → Graphics →
Terrain Detail* to **High**.

### Checking it worked

In `KSP.log` (in the KSP folder) look for:

```
[Parallax] Compute shaders are not supported by OpenGLCore - scatters will be generated on the CPU with Burst jobs
[Parallax] [CPU Scatters] Read biome map for Kerbin (...) in ... ms
```

The *Log Performance Stats* button in the scatter editor (`Ctrl+P`) writes each scatter's on-screen object
counts per LOD to `KSP.log`.

### Performance on an M1 Pro

Scatter placement and culling now share the CPU with KSP's physics instead of running on the GPU. That cost
scales with the number of scatters on screen. If the frame rate drops near the ground, lower the scatter
density and range in Parallax's in-game settings (the toolbar button in the Space Center or in flight). Burst
compiles the jobs to native code, so make sure KSP Burst is working: its log lines appear in `KSP.log` during
loading.

## Running the checks

```bash
scripts/build-mac.sh --skip-plugin --skip-shaders   # just fetch and patch upstream
tests/run-tests.sh
```

This checks that the CPU backend's precomputed transforms match a literal port of the shader's
`GetTRSMatrix` (20,000 random cases), and that the ported noise functions stay in range and are continuous.

## Updating to a newer Parallax release

The patches are made against upstream commit `3cc1f83` (1.0.6 plus a fix for raymarched shadows on OpenGL).
To try another commit, run `PARALLAX_UPSTREAM_COMMIT=<sha> scripts/build-mac.sh`. If a patch no longer
applies, the script stops and names it, and the patch needs updating. Install the matching official release,
because the configs and textures come from there.

## Repository layout

```
patches/                        Changes to upstream, applied in order (git format-patch)
scripts/build-mac.sh            Fetch, patch, build the plugin and the shader bundles
scripts/install-mac.sh          Install into GameData with a backup, or restore one
unity/ParallaxMacShaders/       Minimal Unity project and batch-mode builder for the macOS bundles
                                (the build copies upstream's shaders and ProjectSettings into build/unity-project)
tests/                          Maths checks for the CPU scatter backend
```

## Licence

Parallax Continued is © Gameslinx and **All Rights Reserved** (see the upstream README). The patches in this
repository modify that code, so the upstream terms still apply to it. This repository contains only the
patches, the build tooling and the new CPU scatter code. The DLL and shader bundles you build are for your own
use; don't redistribute them without the author's permission. If the port works out, consider offering it
upstream.
