using System.ComponentModel;
using System.Threading.Tasks;
using ModelContextProtocol.Server;

namespace RR.MCP.Tools;

[McpServerToolType]
public static class PwshInterfacesTool
{
    const string ScriptName = "GetInterfacesPwsh.ps1";
    const string ScriptFolder = "Scripts";

    [McpServerTool, Description("Provides full interface & OpenAPI information for a given .NET solution")]
    public static async Task<string> GetInterfaces([Description("Path to the solution .sln file")] string solutionFile = "MySolution.sln")
        => await PwshScriptRunner.RunScript(ScriptName, ScriptFolder, solutionFile);
} 