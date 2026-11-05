using ImageAgent.Core;

namespace ImageAgent.Diagnostics;
internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        if (args.Contains("--help"))
        {
            Console.WriteLine("""
                ImageAgentDiagnostics [--output DIRECTORY]
                  No live flags / --local  Isolated local SQLite, memory and image checks.
                  --streaming          Offline incremental SSE, terminal/interruption gates and prompt persistence.
                  --region             Offline regional engine, exact alpha mask and outside-pixel checks.
                  --recover-response FILE  Offline recovery of existing native Base64 image outputs; unverified, no HTTP.
                  --live-generate      Explicitly plan and generate one image; billed, never automatically replayed.
                  --live-edit          Explicitly edit a saved result or --reference FILE; billed.
                  --live-region        One planned masked edit of --reference FILE; billed, never creates a base image.
                  --reference FILE     Local image for whole-image or region editing.
                  --region-rect X,Y,W,H Rectangle in oriented original-image pixels.
                  --model MODEL        Exact gpt-image-2, gpt-image-2.5-flare, gpt-image-2.5 or gpt-image-2.5-sunburst.
                  --size SIZE          auto, 1024x1024, 1536x1024 or 1024x1536; region uses auto.
                  --quality QUALITY    auto, low, medium or high; diagnostic default low.
                  --prompt TEXT        Optional generation request.
                  --edit-prompt TEXT   Optional edit request.
                Live mode only consumes OPENAI_BASE_URL and OPENAI_API_KEY from this process and clears both variables.
                No OS credentials or other application configuration is read. Existing attempts are never replayed.
                """);
            return 0;
        }

        try
        {
            var runner = new DiagnosticRunner(args);
            var report = await runner.Run();
            foreach (var item in report.Events)
            {
                Console.WriteLine($"{item.Name}: {item.Status} — {item.Detail}");
                foreach (var path in item.ImagePaths)
                    Console.WriteLine("image: " + path);
            }

            Console.WriteLine("report: " + Path.Combine(runner.OutputDirectory!, "report.json"));
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("ImageAgentDiagnostics: " + e.Message);
            return 1;
        }
    }
}
