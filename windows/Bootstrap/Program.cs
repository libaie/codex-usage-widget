using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex Usage Widget")]
[assembly: AssemblyProduct("Codex Usage Widget")]
[assembly: AssemblyVersion("1.1.1.0")]
[assembly: AssemblyFileVersion("1.1.1.0")]

internal static class Program
{
    const string ZipResource = "CodexUsageWidget.PayloadZip";
    const string ManifestResource = "CodexUsageWidget.PayloadManifest";
    static string selfTestPhase = "startup";

    sealed class FileRecord
    {
        internal string Path;
        internal long Length;
        internal string Hash;
    }

    sealed class Bundle
    {
        internal string Version;
        internal byte[] ZipBytes;
        internal Dictionary<string, FileRecord> Files;
    }

    [STAThread]
    static int Main(string[] args)
    {
        bool selfTest = args.Length == 1 && String.Equals(args[0], "--self-test", StringComparison.Ordinal);
        if (args.Length != 0 && !selfTest) return 2;
        bool ownsMutex = false;
        using (Mutex mutex = new Mutex(false, "Local\\CodexUsageWidget.Bootstrap.v1"))
        {
            try
            {
                try { ownsMutex = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex) return 3;
                Bundle bundle = LoadBundle();
                if (selfTest)
                {
                    RunSelfTest(bundle);
                    byte[] message = new UTF8Encoding(false).GetBytes("引导程序自检通过。\r\n");
                    using (Stream output = Console.OpenStandardOutput()) output.Write(message, 0, message.Length);
                    return 0;
                }

                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (String.IsNullOrWhiteSpace(local)) return 4;
                string appRoot = Path.Combine(local, "CodexUsageWidget");
                string installed = InstallBundle(bundle, appRoot);
                LaunchWidget(installed);
                return 0;
            }
            catch (Exception error)
            {
                if (selfTest)
                {
                    try { Console.Error.WriteLine("SELFTEST:" + error.GetType().Name + ":" + selfTestPhase + ":" + error.HResult.ToString("x8", CultureInfo.InvariantCulture)); }
                    catch { }
                }
                if (!selfTest)
                {
                    try { MessageBox.Show("安装或启动用量小组件失败，请重新下载后再试。", "用量小组件", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    catch { }
                }
                return 1;
            }
            finally
            {
                if (ownsMutex) { try { mutex.ReleaseMutex(); } catch { } }
            }
        }
    }

    static Bundle LoadBundle()
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        byte[] zip = ReadResource(assembly, ZipResource);
        string manifestText = new UTF8Encoding(false, true).GetString(ReadResource(assembly, ManifestResource));
        string[] lines = manifestText.Replace("\r\n", "\n").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length < 3) throw new InvalidDataException();
        string[] version = lines[0].Split('\t');
        string[] zipLine = lines[1].Split('\t');
        if (version.Length != 2 || version[0] != "VERSION" || version[1] != "1.1.1" ||
            zipLine.Length != 3 || zipLine[0] != "ZIP") throw new InvalidDataException();
        long zipLength;
        if (!Int64.TryParse(zipLine[1], NumberStyles.None, CultureInfo.InvariantCulture, out zipLength) ||
            zipLength != zip.LongLength || !String.Equals(zipLine[2], Sha256(zip), StringComparison.Ordinal)) throw new InvalidDataException();

        Dictionary<string, FileRecord> files = new Dictionary<string, FileRecord>(StringComparer.OrdinalIgnoreCase);
        for (int i = 2; i < lines.Length; i++)
        {
            string[] fields = lines[i].Split('\t');
            long length;
            if (fields.Length != 4 || fields[0] != "FILE" ||
                !Int64.TryParse(fields[2], NumberStyles.None, CultureInfo.InvariantCulture, out length) || length < 0 ||
                fields[3].Length != 64 || !IsSafePayloadPath(fields[1]) || files.ContainsKey(fields[1])) throw new InvalidDataException();
            files.Add(fields[1], new FileRecord { Path = fields[1], Length = length, Hash = fields[3] });
        }
        ValidateBundleFiles(files);
        return new Bundle { Version = version[1], ZipBytes = zip, Files = files };
    }

    static void ValidateBundleFiles(Dictionary<string, FileRecord> files)
    {
        if (files == null || files.Count == 0 || files.Count > 128) throw new InvalidDataException();
        long total = 0;
        try
        {
            foreach (FileRecord record in files.Values)
            {
                if (record == null || record.Length < 0) throw new InvalidDataException();
                total = checked(total + record.Length);
            }
        }
        catch (OverflowException) { throw new InvalidDataException(); }
        if (total > 64L * 1024L * 1024L) throw new InvalidDataException();
    }

    static byte[] ReadResource(Assembly assembly, string name)
    {
        using (Stream stream = assembly.GetManifestResourceStream(name))
        {
            if (stream == null || stream.Length <= 0 || stream.Length > 16 * 1024 * 1024) throw new InvalidDataException();
            byte[] bytes = new byte[stream.Length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read <= 0) throw new EndOfStreamException();
                offset += read;
            }
            return bytes;
        }
    }

    static bool IsSafePayloadPath(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || path.Length > 512 || path.IndexOf('\\') >= 0 ||
            path.IndexOf(':') >= 0 || path.StartsWith("/", StringComparison.Ordinal) ||
            !path.StartsWith("CodexUsageWidget/", StringComparison.Ordinal)) return false;
        string[] parts = path.Split('/');
        foreach (string part in parts)
            if (part.Length == 0 || part == "." || part == "..") return false;
        return true;
    }

    static string InstallBundle(Bundle bundle, string appRoot)
    {
        string runtimeRoot = Path.GetFullPath(Path.Combine(appRoot, "app"));
        Directory.CreateDirectory(runtimeRoot);
        RejectReparsePoint(runtimeRoot);
        string target = Path.Combine(runtimeRoot, "v" + bundle.Version);
        string backup = target + ".previous";
        CleanupStagingDirectories(runtimeRoot, Path.GetFileName(target));
        if (VerifyDirectory(backup, bundle.Files) && !VerifyDirectory(target, bundle.Files))
        {
            DeleteRuntimeDirectory(target, runtimeRoot);
            Directory.Move(backup, target);
        }
        if (VerifyDirectory(target, bundle.Files)) return target;

        string staging = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            ExtractBundle(bundle, staging);
            if (!VerifyDirectory(staging, bundle.Files)) throw new InvalidDataException();
            if (Directory.Exists(backup)) DeleteRuntimeDirectory(backup, runtimeRoot);
            if (Directory.Exists(target))
            {
                RejectReparseTree(target);
                Directory.Move(target, backup);
            }
            try { Directory.Move(staging, target); }
            catch
            {
                if (!Directory.Exists(target) && Directory.Exists(backup)) Directory.Move(backup, target);
                throw;
            }
            if (!VerifyDirectory(target, bundle.Files)) throw new InvalidDataException();
            if (Directory.Exists(backup)) DeleteRuntimeDirectory(backup, runtimeRoot);
            return target;
        }
        finally
        {
            if (Directory.Exists(staging)) DeleteRuntimeDirectory(staging, runtimeRoot);
        }
    }

    static void ExtractBundle(Bundle bundle, string staging)
    {
        Directory.CreateDirectory(staging);
        string prefix = Path.GetFullPath(staging).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Dictionary<string, bool> seen = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        using (MemoryStream memory = new MemoryStream(bundle.ZipBytes, false))
        using (ZipArchive archive = new ZipArchive(memory, ZipArchiveMode.Read, false))
        {
            if (archive.Entries.Count != bundle.Files.Count) throw new InvalidDataException();
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                FileRecord record;
                if (String.IsNullOrEmpty(entry.Name) || !bundle.Files.TryGetValue(entry.FullName, out record) ||
                    !String.Equals(record.Path, entry.FullName, StringComparison.Ordinal) || seen.ContainsKey(entry.FullName) ||
                    entry.Length != record.Length) throw new InvalidDataException();
                seen.Add(entry.FullName, true);
                string destination = Path.GetFullPath(Path.Combine(staging, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                if (!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                using (Stream input = entry.Open())
                using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    input.CopyTo(output);
                if (new FileInfo(destination).Length != record.Length || !String.Equals(Sha256File(destination), record.Hash, StringComparison.Ordinal))
                    throw new InvalidDataException();
            }
        }
    }

    static bool VerifyDirectory(string root, Dictionary<string, FileRecord> files)
    {
        try
        {
            if (!Directory.Exists(root)) return false;
            RejectReparseTree(root);
            string fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string[] actual = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
            if (actual.Length != files.Count) return false;
            Dictionary<string, bool> seen = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (string file in actual)
            {
                string relative = file.Substring(fullRoot.Length).Replace(Path.DirectorySeparatorChar, '/');
                FileRecord record;
                if (!files.TryGetValue(relative, out record) || !String.Equals(relative, record.Path, StringComparison.Ordinal) ||
                    seen.ContainsKey(relative) || new FileInfo(file).Length != record.Length ||
                    !String.Equals(Sha256File(file), record.Hash, StringComparison.Ordinal)) return false;
                seen.Add(relative, true);
            }
            return seen.Count == files.Count;
        }
        catch { return false; }
    }

    static void RejectReparseTree(string root)
    {
        RejectReparsePoint(root);
        foreach (string directory in Directory.GetDirectories(root, "*", SearchOption.AllDirectories)) RejectReparsePoint(directory);
        foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories)) RejectReparsePoint(file);
    }

    static void RejectReparsePoint(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
    }

    static void DeleteRuntimeDirectory(string path, string runtimeRoot)
    {
        if (!Directory.Exists(path)) return;
        string fullRoot = Path.GetFullPath(runtimeRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string full = Path.GetFullPath(path);
        if (!full.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
        RejectReparseTree(full);
        Directory.Delete(full, true);
    }

    static void CleanupStagingDirectories(string runtimeRoot, string versionName)
    {
        string prefix = versionName + ".";
        foreach (string directory in Directory.GetDirectories(runtimeRoot, prefix + "*.tmp", SearchOption.TopDirectoryOnly))
        {
            string name = Path.GetFileName(directory);
            string token = name.Substring(prefix.Length, name.Length - prefix.Length - 4);
            Guid ignored;
            if (token.Length == 32 && Guid.TryParseExact(token, "N", out ignored)) DeleteRuntimeDirectory(directory, runtimeRoot);
        }
    }

    static void LaunchWidget(string installedRoot)
    {
        string script = Path.Combine(installedRoot, "CodexUsageWidget", "CodexUsageWidget.ps1");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(script) || !File.Exists(powershell)) throw new FileNotFoundException();
        ProcessStartInfo info = new ProcessStartInfo();
        info.FileName = powershell;
        info.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + script + "\"";
        info.WorkingDirectory = Path.GetDirectoryName(script);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.WindowStyle = ProcessWindowStyle.Hidden;
        if (Process.Start(info) == null) throw new InvalidOperationException();
    }

    static void RunSelfTest(Bundle bundle)
    {
        string temp = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "CodexUsageWidget-bootstrap-selftest-" + Guid.NewGuid().ToString("N")));
        string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!temp.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
        selfTestPhase = "payload-limit";
        Dictionary<string, FileRecord> oversized = new Dictionary<string, FileRecord>(StringComparer.OrdinalIgnoreCase);
        oversized.Add("CodexUsageWidget/large", new FileRecord { Path = "CodexUsageWidget/large", Length = 64L * 1024L * 1024L + 1L, Hash = new string('0', 64) });
        bool sizeRejected = false;
        try { ValidateBundleFiles(oversized); }
        catch (InvalidDataException) { sizeRejected = true; }
        if (!sizeRejected) throw new InvalidDataException();
        try
        {
            selfTestPhase = "install";
            string installed = InstallBundle(bundle, temp);
            string expected = Path.Combine(temp, "app", "v" + bundle.Version);
            if (!String.Equals(installed, expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
            selfTestPhase = "verify";
            if (!VerifyDirectory(installed, bundle.Files)) throw new InvalidDataException();
            selfTestPhase = "repeat";
            if (!String.Equals(InstallBundle(bundle, temp), installed, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
            selfTestPhase = "orphan";
            string orphan = installed + "." + Guid.NewGuid().ToString("N") + ".tmp";
            Directory.CreateDirectory(orphan);
            File.WriteAllText(Path.Combine(orphan, "interrupted"), "test", Encoding.ASCII);
            InstallBundle(bundle, temp);
            if (Directory.Exists(orphan)) throw new InvalidDataException();
            selfTestPhase = "corrupt";
            string script = Path.Combine(installed, "CodexUsageWidget", "CodexUsageWidget.ps1");
            File.WriteAllText(script, "broken", Encoding.ASCII);
            selfTestPhase = "repair";
            if (!VerifyDirectory(InstallBundle(bundle, temp), bundle.Files)) throw new InvalidDataException();
            selfTestPhase = "interrupt";
            string backup = installed + ".previous";
            Directory.Move(installed, backup);
            selfTestPhase = "recover";
            if (!VerifyDirectory(InstallBundle(bundle, temp), bundle.Files) || Directory.Exists(backup)) throw new InvalidDataException();
        }
        finally
        {
            selfTestPhase = "cleanup";
            if (Directory.Exists(temp))
            {
                RejectReparseTree(temp);
                Directory.Delete(temp, true);
            }
        }
    }

    static string Sha256(byte[] bytes)
    {
        using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(bytes));
    }

    static string Sha256File(string path)
    {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(stream));
    }

    static string Hex(byte[] bytes)
    {
        StringBuilder text = new StringBuilder(bytes.Length * 2);
        foreach (byte value in bytes) text.Append(value.ToString("x2", CultureInfo.InvariantCulture));
        return text.ToString();
    }
}
