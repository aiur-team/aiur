defmodule Mix.Tasks.Aiur.Test.Reset do
  @shortdoc "Reset the events sandbox to a clean baseline"

  @moduledoc """
  Wipes per-ticket state for the events sandbox so the manual
  end-to-end test can be re-run. Four safety guards (pinned ticket IDs,
  clean git tree, expected remote, dry-run by default).

  Two modes:

    - **Three-ticket** (default, invoked from `aiur --test3`): resets
      the 3-ticket blocker-chain sandbox pinned in
      `.aiur-test-tickets.json#tickets`.

    - **Single** (`--single`, invoked from `aiur --test`): resets only
      the first pinned ticket (issue 99) so a single-agent run can be
      driven end-to-end.

  ## Examples

      mix aiur.test.reset                        # 3-ticket dry-run
      mix aiur.test.reset --confirm              # 3-ticket reset
      mix aiur.test.reset --single --confirm     # single-ticket reset
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
          allow_remote: :boolean,
          single: :boolean
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
