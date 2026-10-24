using System;
using System.Reflection;
using BepInEx;
using BepInEx.Logging;
using HarmonyLib;

namespace VibesSmoke
{
    // The smoke plugin proves the toolchain, not a mod: it must compile against
    // BepInEx.dll and 0Harmony.dll ALONE. BaseUnityPlugin derives from
    // UnityEngine.MonoBehaviour, and the pak ships no Unity assembly (design
    // section 1), so this type stays a plain class and exercises the attribute,
    // the logger and Harmony's API surface instead. The server's real templates
    // derive from BaseUnityPlugin against the HARVESTED UnityEngine.CoreModule.
    [BepInPlugin(Guid, Name, Version)]
    public sealed class SmokePlugin
    {
        public const string Guid = "com.phvalheim.vibes.smoke";
        public const string Name = "Hugin's Vibes smoke plugin";
        public const string Version = "1.0.0";

        private static readonly ManualLogSource Log = Logger.CreateLogSource(Name);

        public static void Awake()
        {
            var harmony = new Harmony(Guid);
            harmony.PatchAll(Assembly.GetExecutingAssembly());
            Log.LogInfo("smoke: Harmony " + typeof(Harmony).Assembly.GetName().Version
                        + ", BepInEx " + typeof(BaseUnityPlugin).Assembly.GetName().Version);
        }
    }

    // A real-shaped patch (prefix on a BCL method) so the compiler resolves
    // HarmonyPatch, HarmonyPrefix and the __result convention end to end.
    [HarmonyPatch(typeof(Environment), nameof(Environment.GetEnvironmentVariable), typeof(string))]
    internal static class EnvironmentPatch
    {
        [HarmonyPrefix]
        private static bool Prefix(string variable, ref string __result)
        {
            if (variable != "VIBES_SMOKE") return true;
            __result = "ok";
            return false;
        }
    }
}
