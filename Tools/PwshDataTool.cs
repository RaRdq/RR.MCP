using System.ComponentModel;
using System.Threading.Tasks;
using ModelContextProtocol.Server;

namespace RR.MCP.Tools;

[McpServerToolType]
public static class PwshDataTool
{
    const string ScriptName = "GetDataPwsh.ps1";
    const string ScriptFolder = "Scripts";

    [McpServerTool, Description("Provides all models/entities/enums structure for a given .NET solution")]
    public static async Task<string> GetData([Description("Path to the solution .sln file")] string solutionFile = "MySolution.sln")
        => await PwshScriptRunner.RunScript(ScriptName, ScriptFolder, solutionFile);
} 