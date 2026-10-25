using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

/// <summary>
/// Builds Parallax Continued's macOS shader bundles (Parallax*-macosx.unity3d) with Metal and OpenGL Core programs.
///
/// Run by scripts/build-mac.sh:
///   Unity -batchmode -quit -projectPath unity-project -executeMethod ParallaxMacBundleBuilder.BuildFromCommandLine -parallaxOutput out/Shaders
///
/// The bundle contents match upstream's (Assets/Scripts/Tools/ExportAssetBundle.cs builds them from a manual selection),
/// as listed in ParallaxContinued/Config/AssetBundleList.cfg.
/// </summary>
public static class ParallaxMacBundleBuilder
{
    const string ShaderRoot = "Assets/Shaders";

    struct BundleDefinition
    {
        public string name;
        public string folder;
        public bool recursive;
        public bool compute;

        public BundleDefinition(string name, string folder, bool recursive, bool compute = false)
        {
            this.name = name;
            this.folder = folder;
            this.recursive = recursive;
            this.compute = compute;
        }
    }

    static readonly BundleDefinition[] Bundles =
    {
        new BundleDefinition("ParallaxTerrain", "Terrain", true),
        new BundleDefinition("ParallaxScaled", "Scaled", true),
        new BundleDefinition("ParallaxScatters", "Scatters/InstancingShaders", false),
        new BundleDefinition("ParallaxCompute", "Scatters", false, compute: true),
        new BundleDefinition("ParallaxDebug", "Debug", false),
    };

    [MenuItem("Parallax/Build macOS Shader Bundles")]
    public static void BuildFromMenu()
    {
        string output = EditorUtility.SaveFolderPanel("Output folder for the macOS shader bundles", "", "");
        if (!string.IsNullOrEmpty(output))
        {
            Build(output);
        }
    }

    public static void BuildFromCommandLine()
    {
        try
        {
            string output = GetArgument("-parallaxOutput");
            if (string.IsNullOrEmpty(output))
            {
                throw new ArgumentException("Pass the output folder with -parallaxOutput <path>");
            }
            Build(output);
            EditorApplication.Exit(0);
        }
        catch (Exception e)
        {
            Debug.LogException(e);
            EditorApplication.Exit(1);
        }
    }

    static void Build(string outputFolder)
    {
        // KSP on macOS uses OpenGL Core by default and Metal with -force-metal, so compile both
        PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.StandaloneOSX, false);
        PlayerSettings.SetGraphicsAPIs(BuildTarget.StandaloneOSX, new[] { GraphicsDeviceType.Metal, GraphicsDeviceType.OpenGLCore });

        if (PlayerSettings.colorSpace != ColorSpace.Gamma)
        {
            throw new InvalidOperationException("KSP renders in gamma colour space, but the project is set to " + PlayerSettings.colorSpace + ". Copy upstream's ProjectSettings into the project.");
        }

        string platformInclude = File.ReadAllText(Path.Combine(ShaderRoot, "Scatters/InstancingShaders/ParallaxScatterPlatform.cginc"));
        if (!platformInclude.Contains("#define PARALLAX_TEXTURE_INSTANCING_GLCORE"))
        {
            throw new InvalidOperationException("ParallaxScatterPlatform.cginc must define PARALLAX_TEXTURE_INSTANCING_GLCORE for the macOS bundles, or the OpenGL scatter shaders will not compile on macOS");
        }

        AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
        Directory.CreateDirectory(outputFolder);

        BuildAssetBundleOptions options = BuildAssetBundleOptions.DeterministicAssetBundle | BuildAssetBundleOptions.ForceRebuildAssetBundle;
        foreach (BundleDefinition bundle in Bundles)
        {
            Object[] assets = CollectAssets(bundle);
            if (assets.Length == 0)
            {
                throw new InvalidOperationException("No shaders found for " + bundle.name + " in " + bundle.folder);
            }

            string path = Path.Combine(outputFolder, bundle.name + "-macosx.unity3d");
            Debug.Log("[ParallaxMac] Building " + path + " with " + assets.Length + " shaders: " + string.Join(", ", assets.Select(x => x.name)));

            // The legacy API, as used upstream, so the bundles are laid out exactly like the official ones
#pragma warning disable CS0618
            bool built = BuildPipeline.BuildAssetBundle(assets[0], assets, path, options, BuildTarget.StandaloneOSX);
#pragma warning restore CS0618
            if (!built)
            {
                throw new InvalidOperationException("Failed to build " + path);
            }
        }

        Debug.Log("[ParallaxMac] Built " + Bundles.Length + " bundles in " + outputFolder);
    }

    static Object[] CollectAssets(BundleDefinition bundle)
    {
        string folder = ShaderRoot + "/" + bundle.folder;
        string filter = bundle.compute ? "t:ComputeShader" : "t:Shader";

        List<Object> assets = new List<Object>();
        foreach (string guid in AssetDatabase.FindAssets(filter, new[] { folder }))
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            if (!bundle.recursive && Path.GetDirectoryName(path).Replace('\\', '/') != folder)
            {
                continue;
            }

            Object asset = bundle.compute
                ? (Object)AssetDatabase.LoadAssetAtPath<ComputeShader>(path)
                : AssetDatabase.LoadAssetAtPath<Shader>(path);
            if (asset != null)
            {
                assets.Add(asset);
            }
        }

        // Stable order, so rebuilds are deterministic
        return assets.OrderBy(x => AssetDatabase.GetAssetPath(x), StringComparer.Ordinal).ToArray();
    }

    static string GetArgument(string name)
    {
        string[] args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == name)
            {
                return args[i + 1];
            }
        }
        return null;
    }
}
