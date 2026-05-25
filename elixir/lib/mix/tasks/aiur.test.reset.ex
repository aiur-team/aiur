defmodule Mix.Tasks.Aiur.Test.Reset do
  @shortdoc "Reset the 3-ticket events sandbox to a clean baseline"

  @moduledoc """
  Wipes per-ticket state for the 3-ticket events sandbox so the manual
  end-to-end test can be re-run. Four safety guards (pinned ticket IDs,
  clean git tree, expected remote, dry-run by default).

  ## Examples

      mix aiur.test.reset                        # dry-run (default)
      mix aiur.test.reset --confirm              # actually do it
      mix aiur.test.reset --confirm --force      # bypass clean-tree guard
      mix aiur.test.reset --confirm --allow-remote   # bypass remote guard

  See `Aiur.TestReset` for details on each guard and what the reset does.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          confirm: :boolean,
          force: :boolean,
          allow_remote: :boolean
        ]
      )

    # The reset module itself does no GenServer calls — `Aiur` doesn't
    # need to be started. This is a pure I/O orchestrator on top of
    # `git`, `gh`, and local file ops.
    repo_root =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
        {path, 0} -> String.trim(path)
        _ -> File.cwd!()
      end

    opts =
      opts
      |> Keyword.put(:repo_root, repo_root)
      |> Map.new()

    case Aiur.TestReset.run(opts) do
      :ok ->
        :ok

      {:error, _reason} ->
        System.halt(1)
    end
  end
end
