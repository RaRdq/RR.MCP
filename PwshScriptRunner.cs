using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Serilog;

namespace RR.MCP;

public static class PwshScriptRunner
{
    public static async Task<string> RunScript(string scriptName, string scriptFolder, string solutionFile)
    {
        try
        {
            var scriptPath = FindScript(scriptName, scriptFolder);
            if (scriptPath == null)
            {
                var msg = $"Could not find {scriptName} script in {scriptFolder}.";
                Log.Error(msg);
                throw new FileNotFoundException(msg);
            }
            var startInfo = new ProcessStartInfo
            {
                FileName = "pwsh",
                Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{scriptPath}\" -SolutionFile \"{solutionFile}\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var process = new Process { StartInfo = startInfo };
            var output = new StringBuilder();
            var error = new StringBuilder();
            process.OutputDataReceived += (sender, e) => { if (e.Data != null) output.AppendLine(e.Data); };
            process.ErrorDataReceived += (sender, e) => { if (e.Data != null) error.AppendLine(e.Data); };
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync();
            var outputStr = output.ToString().Trim();
            if (process.ExitCode != 0)
            {
                var msg = $"PowerShell script error (code {process.ExitCode}): {error}";
                Log.Error(msg);
                return $"Error: {msg}";
            }
            if (string.IsNullOrEmpty(outputStr))
            {
                var msg = $"No output from script. Error: {error}";
                Log.Error(msg);
                return $"Error: {msg}";
            }
            try
            {
                var jsonStart = outputStr.IndexOf('{');
                var jsonEnd = outputStr.LastIndexOf('}') + 1;
                if (jsonStart >= 0 && jsonEnd > jsonStart)
                    return outputStr.Substring(jsonStart, jsonEnd - jsonStart);
                return outputStr;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to process script output");
                return $"Error processing script output: {ex.Message}";
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Exception in PwshScriptRunner");
            return $"Error: {ex.Message}";
        }
    }

    static string? FindScript(string scriptName, string scriptFolder)
    {
        var exeDir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule?.FileName ?? "");
        var currentDir = Directory.GetCurrentDirectory();
        var searchPaths = new[]
        {
            Path.Combine(exeDir!, scriptFolder, scriptName),
            Path.Combine(currentDir, scriptFolder, scriptName),
            Path.Combine(currentDir, scriptName),
            Path.Combine(currentDir, "RR.MCP", scriptFolder, scriptName)
        };
        foreach (var path in searchPaths)
            if (File.Exists(path)) return path;
        return null;
    }
} 