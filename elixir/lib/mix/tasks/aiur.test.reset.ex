defmodule Mix.Tasks.Aiur.Test.Reset do
  @shortdoc "Reset the events sandbox to a clean baseline"

  @moduledoc """
  Wipes per-ticket state for the events sandbox so the manual
  end-to-end test can be re-run. Four safety guards (pinned ticket IDs,
  clean git tree, expected remote, dry-run by default).

  Three modes:

    - **Three-ticket** (default, invoked from `aiur --test3`): resets
      the 3-ticket blocker-chain sandbox pinned in
      `.aiur-test-tickets.json#tickets`.

    - **Golden** (`--golden`, invoked from `aiur --test`): reuses or
      auto-creates one fixed complexity:2 ticket whose body exercises
      every chat-render surface (file edit/diff, shell command, tool
      call, skill) so codex and Claude runs compare 1:1.

    - **Single-ticket** (`--single`, invoked from `aiur --test1`):
      reuses or auto-creates one complexity:1 ticket asking for a
      one-line const in the sandbox. Minimum-overhead surface for
      manually testing things like progress emits.

  ## Examples

      mix aiur.test.reset                        # 3-ticket dry-run
      mix aiur.test.reset --confirm              # 3-ticket reset
      mix aiur.test.reset --golden --confirm     # golden-ticket reset
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
          single: :boolean,
          golden: :boolean
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
