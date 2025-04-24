using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Serilog;

namespace RR.MCP
{
    public class Program
    {
        public static async Task Main(string[] args)
        {
            var baseDir = AppContext.BaseDirectory;
            var logFilePath = Path.Combine(baseDir, "mcp_errors.log");
            Log.Logger = new LoggerConfiguration()
                .WriteTo.File(logFilePath, rollingInterval: RollingInterval.Day)
                .CreateLogger();
            try
            {
                var builder = Host.CreateEmptyApplicationBuilder(settings: null);
                builder.Services
                    .AddMcpServer()
                    .WithStdioServerTransport()
                    .WithToolsFromAssembly();
                await builder.Build().RunAsync();
            }
            catch (Exception ex)
            {
                Log.Fatal(ex, "Fatal error in MCP server");
                throw;
            }
            finally
            {
                await Log.CloseAndFlushAsync();
            }
        }
    }
} 