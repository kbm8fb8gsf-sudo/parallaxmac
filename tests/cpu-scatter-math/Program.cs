using System;
using Unity.Mathematics;
using Parallax;

// Literal port of GetTRSMatrix and friends from ScatterUtils.cginc, with HLSL's row-major conventions spelled out.
// The CPU backend precomputes most of this at distribution time, so check both give the same object to world matrix.
static class Hlsl
{
    const float DEG2RAD = 0.01745329251f;

    // HLSL float4x4(float4 a, b, c, d) takes rows, Unity.Mathematics takes columns
    public static float4x4 Rows(float4 a, float4 b, float4 c, float4 d) => math.transpose(new float4x4(a, b, c, d));
    public static float4 Row(float4x4 m, int i) => math.transpose(m)[i];

    static float4x4 GetTranslationMatrix(float3 pos) =>
        Rows(new float4(1, 0, 0, pos.x), new float4(0, 1, 0, pos.y), new float4(0, 0, 1, pos.z), new float4(0, 0, 0, 1));

    static float4x4 GetRotationMatrix(float3 anglesDeg)
    {
        float3 a = anglesDeg * DEG2RAD;
        float4x4 rotationX = Rows(new float4(1, 0, 0, 0), new float4(0, math.cos(a.x), -math.sin(a.x), 0), new float4(0, math.sin(a.x), math.cos(a.x), 0), new float4(0, 0, 0, 1));
        float4x4 rotationY = Rows(new float4(math.cos(a.y), 0, math.sin(a.y), 0), new float4(0, 1, 0, 0), new float4(-math.sin(a.y), 0, math.cos(a.y), 0), new float4(0, 0, 0, 1));
        float4x4 rotationZ = Rows(new float4(math.cos(a.z), -math.sin(a.z), 0, 0), new float4(math.sin(a.z), math.cos(a.z), 0, 0), new float4(0, 0, 1, 0), new float4(0, 0, 0, 1));
        return math.mul(rotationY, math.mul(rotationX, rotationZ));
    }

    static float4x4 GetScaleMatrix(float3 s) =>
        Rows(new float4(s.x, 0, 0, 0), new float4(0, s.y, 0, 0), new float4(0, 0, s.z, 0), new float4(0, 0, 0, 1));

    static float4x4 TransformToPlanetNormal(float3 a, float3 b)
    {
        float3 v = math.cross(a, b);
        float v1 = v.x, v2 = v.y, v3 = v.z;
        float c = math.dot(a, b);
        float onePlusC = c >= 0 ? 1 + c : math.dot(v, v) / (1 - c);
        if (onePlusC <= 0)
        {
            float3 axis = math.normalize(math.cross(a, math.abs(a.z) < 0.9f ? new float3(0, 0, 1) : new float3(1, 0, 0)));
            return Rows(new float4(2 * axis.x * axis - new float3(1, 0, 0), 0), new float4(2 * axis.y * axis - new float3(0, 1, 0), 0),
                        new float4(2 * axis.z * axis - new float3(0, 0, 1), 0), new float4(0, 0, 0, 1));
        }
        float4x4 V = Rows(new float4(0, v3, -v2, 0), new float4(-v3, 0, v1, 0), new float4(v2, -v1, 0, 0), new float4(0, 0, 0, 1));
        float4x4 VPlusI = Rows(new float4(1, v3, -v2, 0), new float4(-v3, 1, v1, 0), new float4(v2, -v1, 1, 0), new float4(0, 0, 0, 1));
        float4x4 halfMat = math.mul(V, V) * (1 / onePlusC);
        float4x4 full = math.transpose(halfMat + VPlusI);
        // full[0].w = full[1].w = full[2].w = 0, full[3] = (0, 0, 0, 1)
        full.c3 = new float4(0, 0, 0, 1);
        full.c0.w = 0; full.c1.w = 0; full.c2.w = 0;
        return full;
    }

    public static float4x4 GetTRSMatrix(float4x4 objectToWorld, int alignToTerrainNormal, float3 planetNormal, float3 position, float3 rotationAngles, float3 scale, float3 terrainNormal)
    {
        float3 nrm = alignToTerrainNormal == 0 ? math.normalize(planetNormal) : math.normalize(terrainNormal);
        float3x3 quadToWorld = new float3x3(objectToWorld);
        quadToWorld /= math.length(quadToWorld.c0);
        float3 localNrm = math.mul(math.transpose(quadToWorld), nrm);
        float4x4 mat = TransformToPlanetNormal(new float3(0, 1, 0), localNrm);
        mat = math.mul(mat, GetRotationMatrix(rotationAngles));
        float3x3 rows = math.transpose(quadToWorld);
        float4x4 quadRotation = Rows(new float4(rows.c0, 0), new float4(rows.c1, 0), new float4(rows.c2, 0), new float4(0, 0, 0, 1));
        mat = math.mul(quadRotation, mat);
        return math.mul(GetTranslationMatrix(position), math.mul(mat, GetScaleMatrix(scale)));
    }
}

static class Program
{
    static Unity.Mathematics.Random rng = new Unity.Mathematics.Random(12345);
    static int failures = 0;

    static float3 RandomDirection() => math.normalize(rng.NextFloat3(-1, 1));

    static void Check(bool ok, string message)
    {
        Console.WriteLine((ok ? "PASS  " : "FAIL  ") + message);
        if (!ok) failures++;
    }

    static int Main()
    {
        CheckTransformParity();
        CheckNoise();
        Console.WriteLine(failures == 0 ? "All checks passed" : failures + " check(s) failed");
        return failures == 0 ? 0 : 1;
    }

    static void CheckTransformParity()
    {
        float worst = 0;
        for (int i = 0; i < 20000; i++)
        {
            // A quad transform: rotation, uniform scale, translation
            float4x4 objectToWorld = float4x4.TRS(rng.NextFloat3(-5000, 5000), quaternion.AxisAngle(RandomDirection(), rng.NextFloat(-math.PI, math.PI)), new float3(rng.NextFloat(0.5f, 2f)));

            float3 localPos = rng.NextFloat3(-100, 100);
            float3 worldPos = math.mul(objectToWorld, new float4(localPos, 1)).xyz;
            float rotation = rng.NextFloat(0, 180);
            float3 scale = rng.NextFloat3(0.2f, 3f);
            int alignToTerrainNormal = i % 2;
            // A normal exactly opposite to up has no unique rotation, which random directions never hit
            float3 faceNormal = RandomDirection();
            float3 planetNormal = RandomDirection();

            // What the Evaluate kernel computes
            float4x4 expected = Hlsl.GetTRSMatrix(objectToWorld, alignToTerrainNormal, planetNormal, worldPos, new float3(0, rotation, 0), scale,
                                                  math.mul(objectToWorld, new float4(faceNormal, 0)).xyz);

            // What CpuDistributeJob precomputes and CpuEvaluateJob finishes
            float3x3 quadRotation = new float3x3(objectToWorld);
            quadRotation /= math.length(quadRotation.c0);
            float3 localUp = math.normalize(math.mul(math.transpose(quadRotation), planetNormal));
            float3x3 alignment = CpuScatterMath.TransformToPlanetNormal(new float3(0, 1, 0), alignToTerrainNormal == 0 ? localUp : faceNormal);
            float3x3 localRotationScale = math.mul(alignment, math.mul(CpuScatterMath.RotationY(rotation), float3x3.Scale(scale)));
            float3x3 m = math.mul(quadRotation, localRotationScale);
            float4[] rows =
            {
                new float4(m.c0.x, m.c1.x, m.c2.x, worldPos.x),
                new float4(m.c0.y, m.c1.y, m.c2.y, worldPos.y),
                new float4(m.c0.z, m.c1.z, m.c2.z, worldPos.z),
            };

            float error = 0;
            for (int r = 0; r < 3; r++)
            {
                error = math.max(error, math.cmax(math.abs(Hlsl.Row(expected, r) - rows[r])));
            }
            worst = math.max(worst, error / math.max(1, math.cmax(math.abs(worldPos))));
        }
        Check(worst < 1e-5f, $"object to world matrix matches GetTRSMatrix (worst relative error {worst:E1})");
    }

    static void CheckNoise()
    {
        float perlinMin = float.MaxValue, perlinMax = float.MinValue;
        float cellularMin = float.MaxValue, cellularMax = float.MinValue;
        float polkaMin = float.MaxValue, polkaMax = float.MinValue;
        float maxStep = 0;
        for (int i = 0; i < 200000; i++)
        {
            float3 p = rng.NextFloat3(-50, 50);
            float perlin = CpuScatterMath.SimplexPerlin3D(p);
            float cellular = CpuScatterMath.Cellular3D(p);
            float polka = CpuScatterMath.SimplexPolkaDot3D(p, 0.3f, 1);
            perlinMin = math.min(perlinMin, perlin); perlinMax = math.max(perlinMax, perlin);
            cellularMin = math.min(cellularMin, cellular); cellularMax = math.max(cellularMax, cellular);
            polkaMin = math.min(polkaMin, polka); polkaMax = math.max(polkaMax, polka);
            maxStep = math.max(maxStep, math.abs(CpuScatterMath.SimplexPerlin3D(p + RandomDirection() * 1e-3f) - perlin));
        }
        Check(perlinMin >= -1 && perlinMax <= 1 && perlinMax - perlinMin > 1.5f, $"SimplexPerlin3D spans -1..1 ({perlinMin:F3} to {perlinMax:F3})");
        Check(cellularMin >= 0 && cellularMax <= 1 && cellularMax > 0.5f, $"Cellular3D spans 0..1 ({cellularMin:F3} to {cellularMax:F3})");
        Check(polkaMin >= 0 && polkaMax <= 1 && polkaMax > 0.5f, $"SimplexPolkaDot3D spans 0..1 ({polkaMin:F3} to {polkaMax:F3})");
        Check(maxStep < 0.02f, $"SimplexPerlin3D is continuous (largest change over a 0.001 step: {maxStep:F4})");

        float randMin = 1, randMax = 0, randSum = 0;
        for (int i = 0; i < 100000; i++)
        {
            float r = CpuScatterMath.Rand(rng.NextFloat3(0, 1000));
            randMin = math.min(randMin, r); randMax = math.max(randMax, r); randSum += r;
        }
        Check(randMin >= 0 && randMax < 1 && math.abs(randSum / 100000 - 0.5f) < 0.01f, $"Rand is uniform in 0..1 (mean {randSum / 100000:F3})");
    }
}
