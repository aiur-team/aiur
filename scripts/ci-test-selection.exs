# Resolve xref callers through the same compiled Mix project as local selection.
_paths = System.argv() |> hd() |> File.read!() |> String.split("\n", trim: true)

root = Mix.Project.project_file() |> Path.dirname() |> Path.expand("..")
base = System.get_env("AIUR_BASE_SHA") || "origin/main"

case Mix.Tasks.Aiur.AffectedTests.selection(root, base, true) do
  {:ok, [json]} ->
    selection = Jason.decode!(json)

    case selection do
      %{"status" => "full"} -> IO.puts("full")
      %{"status" => "scoped", "tests" => tests} ->
        IO.puts(:stderr, "affected tests selected: #{length(tests)}")
        IO.puts("scoped:#{length(tests)}")
    end

  {:error, reason} ->
    IO.puts(:stderr, "affected test selection failed: #{reason}")
    IO.puts("full")
end
