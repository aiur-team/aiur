defmodule Aiur.Codex.CodingAgentStartFailureTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Codex.CodingAgent
  alias Aiur.ProviderAccountGeneration

  @child_marker "aiur-codex-start-failure-child"
  @probe_skip_reason if(File.exists?("/proc/self/fd/2"), do: false, else: "requires Linux /proc fd ownership")

  @tag skip: @probe_skip_reason
  @tag :tmp_dir
  test "startup failure reaps a detached child using the captured process group", %{tmp_dir: tmp_dir} do
    workspace_root = Path.join(tmp_dir, "workspaces")
    workspace = Path.join(workspace_root, "issue-1499")
    pid_path = Path.join(tmp_dir, "child.pid")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      with {:ok, pid_string} <- File.read(pid_path),
           {pid, ""} <- pid_string |> String.trim() |> Integer.parse(),
           {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
           true <- String.contains?(cmdline, @child_marker) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end)

    expression = """
    _marker = "#{@child_marker}"
    Process.sleep(10_000)
    """

    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")

    command =
      "#{Aiur.Shell.escape(elixir)} -e #{Aiur.Shell.escape(expression)} & " <>
        "echo $! > #{Aiur.Shell.escape(pid_path)}; exit 0"

    workflow_file = Application.fetch_env!(:aiur, :workflow_file_path)

    write_workflow_file_synced!(workflow_file,
      agent_kind: "codex",
      command: command,
      workspace_root: workspace_root,
      agent_read_timeout_ms: 100
    )

    {:ok, owner} = start_supervised({ProviderAccountGeneration, name: nil})

    assert {:error, _reason} =
             CodingAgent.start_session(workspace,
               identifier: "start-failure",
               account_generation_server: owner
             )

    child_pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    refute os_alive?(child_pid)
  end

  defp os_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end
