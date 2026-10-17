defmodule Aiur.Orchestrator.StatusCLI.PrewarmFixture do
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.RepoBase

  # Prewarm-enabled config for the CLI surface tests. No `base_build` and a
  # memory tracker keep RepoBase's own resolve/poll inert (no clone/build can
  # start) while `Config.prewarm_enabled?/0` reads true.
  def with_prewarm_enabled do
    tmp = Aiur.TestSupport.tmp_root!("cli_prewarm")
    File.mkdir_p!(tmp)
    cfg = Path.join(tmp, "config")
    File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")
    previous = Application.get_env(:aiur, :workflow_file_path)
    Aiur.Workflow.set_workflow_file_path(cfg)

    on_exit(fn ->
      case previous do
        nil -> Aiur.Workflow.clear_workflow_file_path()
        path -> Aiur.Workflow.set_workflow_file_path(path)
      end
    end)

    :ok
  end

  # Drive the live RepoBase phase so `aiur status` renders the prewarm line
  # exactly as it would against a warming/errored base.
  def with_repo_base_phase(phase) do
    pid = Process.whereis(RepoBase) || flunk("RepoBase must be running for prewarm status tests")
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state -> %{state | phase: phase, base_path: "/tmp/base"} end)

    on_exit(fn -> restore_repo_base(pid, original) end)

    :ok
  end

  defp restore_repo_base(pid, original) do
    if Process.alive?(pid), do: :sys.replace_state(pid, fn _state -> original end)
  end
end
