defmodule Mix.Tasks.Aiur.Env.Example do
  use Mix.Task

  @shortdoc "Regenerate .env.example from Aiur.Env.Schema"

  @moduledoc """
  Regenerates the repo-root `.env.example` from `Aiur.Env.Schema`.

      mix aiur.env.example
      mix aiur.env.example --check
      mix aiur.env.example --path /tmp/example.env

  The schema is the single source of truth: names, purpose lines, fetch notes,
  grouping, secret placeholders and alignment are all rendered from it, so the
  checked-in example cannot drift from the declaration. `--check` writes
  nothing and exits non-zero when the file on disk differs from what the
  schema renders. The fast name-level drift gate in CI lives in
  `scripts/check-env-example.py`; this task is the full-content generator.
  """

  @switches [check: :boolean, path: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    content = Aiur.Env.render_example()
    path = Path.expand(Keyword.get(opts, :path, default_path()))
    check? = Keyword.get(opts, :check, false)

    if check? do
      check_file(path, content)
    else
      File.write!(path, content)
      Mix.shell().info("wrote #{path}")
    end
  end

  defp check_file(path, content) do
    case File.read(path) do
      {:ok, existing} ->
        if existing == content do
          Mix.shell().info(".env.example is up to date with the env schema")
        else
          Mix.raise(".env.example drifts from Aiur.Env.Schema; run `mix aiur.env.example` to regenerate")
        end

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{inspect(reason)}; run `mix aiur.env.example` to regenerate")
    end
  end

  defp default_path do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> Path.join(String.trim(root), ".env.example")
      _ -> Path.join(File.cwd!(), "../.env.example")
    end
  end
end
