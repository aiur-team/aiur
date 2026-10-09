defmodule Aiur.Stacking.GitCommand do
  @moduledoc false
  alias Aiur.{AgentEnvironment, AgentGitHubGuard, ProcessTree}
  alias Aiur.Workspace.Ownership

  @credential_helper ~S"""
  !f() { if test "$1" = get; then t=""; f="${AIUR_GITHUB_CREDENTIAL_FILE:-}"; if test -n "$f" && test -f "$f"; then t=$(sed -n "1p" "$f" 2>/dev/null); fi; if test -z "$t"; then printf "quit=true\n"; else printf "username=x-access-token\npassword=%s\n" "$t"; fi; fi; }; f
  """

  @spec run(Path.t(), [String.t()], Ownership.lease() | nil) :: {String.t(), non_neg_integer()}
  def run(workspace, args, lease \\ nil) do
    {port, pid} = start(workspace, args, lease)
    execute(port, pid, args, lease)
  rescue
    _error -> {"git command unavailable", 127}
  end

  defp start(workspace, args, lease) do
    env =
      AgentEnvironment.port_shell_startup_env() ++
        [{~c"GIT_TERMINAL_PROMPT", ~c"0"}, {~c"GITHUB_TOKEN", false}, {~c"GH_TOKEN", false}, {~c"AIUR_GITHUB_CREDENTIAL_FILE", String.to_charlist(AgentGitHubGuard.agent_token_path())}]

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-c", AgentEnvironment.scrub_shell_prefix() <> "; read -r ready && exec \"$@\"", "restack", executable(), "-C", workspace] ++ config() ++ args,
        env: env
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    if lease, do: :ok = Ownership.expect_provider(lease, :local)
    if lease, do: :ok = Ownership.track_provider(lease, %{root_pid: pid, process_group_id: pid})
    Port.command(port, "ready\n")
    {port, pid}
  end

  defp config do
    [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "credential.https://github.com.helper=",
      "-c",
      "credential.https://github.com.helper=#{String.trim(@credential_helper)}",
      "-c",
      "http.https://github.com/.extraheader="
    ]
  end

  defp execute(port, pid, args, lease) do
    deadline = System.monotonic_time(:millisecond) + if(hd(args) in ["fetch", "push"], do: 30_000, else: 5_000)
    owner = self()
    watcher = if is_nil(lease), do: spawn(fn -> watch_owner(owner, pid) end)

    try do
      result = collect(port, pid, deadline, [])

      finish(lease, pid)
      result
    after
      if watcher, do: send(watcher, :finished)
    end
  end

  defp finish(nil, _pid), do: :ok

  defp finish(lease, pid) do
    case ProcessTree.graceful_kill_process_group(pid) do
      {:ok, status} when status in [:gone, :reaped] -> Ownership.mark_provider_cleanup_succeeded(lease)
      _ -> Ownership.mark_provider_cleanup_unknown(lease)
    end
  end

  defp executable do
    candidates = [System.get_env("AIUR_REAL_GIT") | System.get_env("PATH", "") |> String.split(":") |> Enum.map(&Path.join(&1, "git"))]

    Enum.find(candidates, fn path ->
      is_binary(path) and not String.contains?(path, ["/.aiur/bin/", "/github-budget/bin/", "/.aiur-runtime/bin/"]) and File.regular?(path)
    end)
  end

  defp watch_owner(owner, pid) do
    ref = Process.monitor(owner)

    receive do
      :finished -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, ^owner, _reason} -> ProcessTree.graceful_kill_process_group(pid)
    end
  end

  defp collect(port, pid, deadline, chunks) do
    receive do
      {^port, {:data, data}} -> collect(port, pid, deadline, [data | chunks])
      {^port, {:exit_status, status}} -> {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        ProcessTree.graceful_kill_process_group(pid)
        Port.close(port)
        {"git command timed out", 124}
    end
  end
end
