defmodule Mix.Tasks.VoiceConverse.Transcripts do
  @shortdoc "List or show transcripts: --root PATH [ID] [--target TARGET] [--limit N] [--json]"
  @moduledoc "Reads a host's transcript directory without starting the host. --root PATH is required."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, target: :string, limit: :integer, json: :boolean])

    root = opts[:root] || Mix.raise("--root PATH is required")
    if invalid != [], do: Mix.raise("Invalid transcript options: #{inspect(invalid)}")
    forwarded = OptionParser.to_argv(Keyword.delete(opts, :root)) ++ rest
    code = VoiceConverse.Transcripts.print(root, forwarded)
    if code != 0, do: exit({:shutdown, code})
  end
end
