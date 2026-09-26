using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace CodexMonitor {
    public sealed class Snapshot {
        public double? Used;
        public string Status = "Reading Codex usage...";
        public string Project = "No recent local task";
        public long ProjectTokens, TotalTokens, Lifetime;
        public long Reset;
        public int WindowMinutes = 10080;
    }
    public static class Data {
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
        private static readonly object ProcessLock = new object();
        private static Process activeProcess;
        public static void Shutdown() {
            lock (ProcessLock) {
                if (activeProcess != null && !activeProcess.HasExited) activeProcess.Kill();
            }
        }
        public static IDictionary<string, object> Map(object value) { return value as IDictionary<string, object>; }
        public static object Get(object obj, string key) {
            var map = Map(obj); object value;
            return map != null && map.TryGetValue(key, out value) ? value : null;
        }
        public static IDictionary<string, object> Parse(string text) { return Map(Json.DeserializeObject(text)); }
        public static double? Number(object value) {
            if (value == null || value is string || value is bool) return null;
            try { double n = Convert.ToDouble(value); return double.IsNaN(n) || double.IsInfinity(n) ? (double?)null : n; }
            catch (FormatException) { return null; } catch (InvalidCastException) { return null; }
        }
        public static object Primary(object result) {
            var bucket = Get(Get(result, "rateLimitsByLimitId"), "codex");
            if (Map(bucket) == null) bucket = Get(result, "rateLimits");
            var primary = Get(bucket, "primary");
            return Number(Get(primary, "usedPercent")).HasValue ? primary : null;
        }
        public static string Home {
            get { return Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"); }
        }
        private static string Executable() {
            var custom = Environment.GetEnvironmentVariable("CODEX_BINARY");
            if (!string.IsNullOrEmpty(custom) && File.Exists(custom)) return custom;
            // Prefer the running desktop application's bundled CLI, including Store installs.
            foreach (var process in Process.GetProcessesByName("Codex")) {
                using (process) {
                    try {
                        var root = Path.GetDirectoryName(process.MainModule.FileName);
                        foreach (string relative in new[] { "resources/codex.exe", "resources/codex-cli/codex.exe", "codex.exe" }) {
                            var path = Path.Combine(root, relative); if (File.Exists(path)) return path;
                        }
                    } catch (System.ComponentModel.Win32Exception) { } catch (InvalidOperationException) { }
                }
            }
            foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)) {
                if (string.IsNullOrWhiteSpace(directory)) continue;
                var path = Path.Combine(directory.Trim('"'), "codex.exe");
                if (File.Exists(path)) return path;
                // npm's wrapper cannot be started with shell execution disabled. Find its native executable.
                var vendor = Path.Combine(directory, "node_modules", "@openai", "codex", "vendor");
                if (Directory.Exists(vendor)) {
                    var binary = Directory.EnumerateFiles(vendor, "codex.exe", SearchOption.AllDirectories).FirstOrDefault();
                    if (binary != null) return binary;
                }
            }
            throw new FileNotFoundException("Open Codex, or set CODEX_BINARY to the full path of codex.exe.");
        }
        private static object Request(Process p, int id, string method, object parameters) {
            var message = new Dictionary<string, object> { { "id", id }, { "method", method } };
            if (parameters != null) message["params"] = parameters;
            p.StandardInput.WriteLine(Json.Serialize(message)); p.StandardInput.Flush();
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline) {
                var read = p.StandardOutput.ReadLineAsync();
                var wait = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
                if (!read.Wait(wait) || read.Result == null) throw new TimeoutException("Codex response timed out.");
                var response = Parse(read.Result);
                if (Number(Get(response, "id")) != id) continue;
                if (Get(response, "error") != null) return null;
                return Get(response, "result");
            }
            throw new TimeoutException("Codex response timed out.");
        }
        public static Snapshot Read() {
            var snapshot = new Snapshot();
            try {
                using (var p = new Process()) {
                    p.StartInfo = new ProcessStartInfo(Executable(), "app-server") {
                        UseShellExecute = false, CreateNoWindow = true,
                        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
                    };
                    lock (ProcessLock) { p.Start(); activeProcess = p; }
                    p.BeginErrorReadLine();
                    try {
                        var hello = Request(p, 1, "initialize", new { clientInfo = new { name = "codex-token-monitor", version = "1.3.0" }, capabilities = new { experimentalApi = true } });
                        if (hello == null) throw new InvalidOperationException("Codex initialization failed.");
                        p.StandardInput.WriteLine("{\"method\":\"initialized\"}"); p.StandardInput.Flush();
                        var primary = Primary(Request(p, 2, "account/rateLimits/read", null));
                        snapshot.Used = Number(Get(primary, "usedPercent"));
                        if (snapshot.Used.HasValue) snapshot.Used = Math.Max(0, Math.Min(100, snapshot.Used.Value));
                        snapshot.Reset = (long)(Number(Get(primary, "resetsAt")) ?? 0);
                        snapshot.WindowMinutes = (int)(Number(Get(primary, "windowDurationMins")) ?? 10080);
                        if (snapshot.WindowMinutes <= 0) snapshot.WindowMinutes = 10080;
                        snapshot.Status = snapshot.Used.HasValue ? "Codex quota" : "Quota unavailable - check Codex sign-in";
                        var usage = Request(p, 3, "account/usage/read", null);
                        snapshot.Lifetime = (long)(Number(Get(Get(usage, "summary"), "lifetimeTokens")) ?? 0);
                    } finally {
                        lock (ProcessLock) { if (!p.HasExited) p.Kill(); activeProcess = null; }
                        p.WaitForExit();
                    }
                }
            } catch (Exception e) {
                if (!(e is IOException || e is TimeoutException || e is InvalidOperationException || e is System.ComponentModel.Win32Exception)) throw;
                snapshot.Status = e is FileNotFoundException ? e.Message : "Codex unavailable - retrying";
            }
            ReadLocal(snapshot);
            return snapshot;
        }
        private sealed class Rollout {
            public DateTime Modified, LastEvent;
            public string Project;
            public long Lifetime, WindowTokens;
            public long WindowStart;
        }
        private static readonly Dictionary<string, Rollout> Cache = new Dictionary<string, Rollout>(StringComparer.OrdinalIgnoreCase);
        private static void ReadLocal(Snapshot snapshot) {
            var sessions = Path.Combine(Home, "sessions");
            if (!Directory.Exists(sessions)) return;
            long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds;
            long start = snapshot.Reset > 0 ? snapshot.Reset - snapshot.WindowMinutes * 60L : now - 7 * 86400;
            string latestProject = null; DateTime latest = DateTime.MinValue;
            var totals = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            long localLifetime = 0;
            foreach (var file in Directory.EnumerateFiles(sessions, "rollout-*.jsonl", SearchOption.AllDirectories)) {
                try {
                    var modified = File.GetLastWriteTimeUtc(file); Rollout cached;
                    if (!Cache.TryGetValue(file, out cached) || cached.Modified != modified || cached.WindowStart != start) {
                        cached = new Rollout { Modified = modified, WindowStart = start };
                        long baseline = 0, final = 0;
                        using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        using (var reader = new StreamReader(stream)) {
                            string line;
                            while ((line = reader.ReadLine()) != null) {
                                IDictionary<string, object> ev;
                                try { ev = Parse(line); } catch (ArgumentException) { continue; }
                                var payload = Get(ev, "payload");
                                if ((string)Get(ev, "type") == "session_meta") cached.Project = Get(payload, "cwd") as string;
                                var tokens = Number(Get(Get(Get(payload, "info"), "total_token_usage"), "total_tokens"));
                                DateTime timestamp;
                                if (!tokens.HasValue || !DateTime.TryParse(Get(ev, "timestamp") as string, null, System.Globalization.DateTimeStyles.AdjustToUniversal, out timestamp)) continue;
                                final = Math.Max(final, (long)tokens.Value);
                                if ((timestamp - new DateTime(1970, 1, 1)).TotalSeconds < start) baseline = final;
                                cached.LastEvent = timestamp;
                            }
                        }
                        cached.Lifetime = final; cached.WindowTokens = Math.Max(0, final - baseline); Cache[file] = cached;
                    }
                    localLifetime += cached.Lifetime; snapshot.TotalTokens += cached.WindowTokens;
                    if (cached.Project != null) {
                        if (!totals.ContainsKey(cached.Project)) totals[cached.Project] = 0;
                        totals[cached.Project] += cached.WindowTokens;
                        if (cached.LastEvent > latest) { latest = cached.LastEvent; latestProject = cached.Project; }
                    }
                } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            if (snapshot.Lifetime == 0) snapshot.Lifetime = localLifetime;
            if (latestProject != null) { snapshot.Project = Path.GetFileName(latestProject.TrimEnd('\\', '/')); snapshot.ProjectTokens = totals[latestProject]; }
        }
        public static void SelfTest() {
            if (Primary(Parse("{\"rateLimits\":null}")) != null) throw new Exception("Null quota test failed");
            var modern = Parse("{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":25}}},\"rateLimits\":{\"primary\":{\"usedPercent\":90}}}");
            if (Number(Get(Primary(modern), "usedPercent")) != 25) throw new Exception("Bucket priority test failed");
            var legacy = Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":40}}}");
            if (Number(Get(Primary(legacy), "usedPercent")) != 40) throw new Exception("Legacy quota test failed");
            string originalHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            string fixture = Path.Combine(Path.GetTempPath(), "codex-monitor-test-" + Guid.NewGuid());
            try {
                Environment.SetEnvironmentVariable("CODEX_HOME", fixture);
                Directory.CreateDirectory(Path.Combine(fixture, "sessions"));
                string timestamp = DateTime.UtcNow.ToString("o");
                File.WriteAllLines(Path.Combine(fixture, "sessions", "rollout-test.jsonl"), new[] {
                    Json.Serialize(new { type = "session_meta", payload = new { cwd = Path.Combine(fixture, "SampleProject") } }),
                    Json.Serialize(new { timestamp = timestamp, payload = new { info = (object)null } }),
                    Json.Serialize(new { timestamp = timestamp, payload = new { info = new { total_token_usage = new { total_tokens = 1234 } } } })
                });
                var sample = new Snapshot(); ReadLocal(sample);
                if (sample.Project != "SampleProject" || sample.TotalTokens != 1234 || sample.ProjectTokens != 1234 || sample.Lifetime != 1234)
                    throw new Exception("Local rollout fixture test failed");
            } finally {
                Environment.SetEnvironmentVariable("CODEX_HOME", originalHome);
                Cache.Clear(); if (Directory.Exists(fixture)) Directory.Delete(fixture, true);
            }
        }
    }
}
