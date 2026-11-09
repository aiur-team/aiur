defmodule Aiur.Handoff.CLI do
  @moduledoc "CLI boundary for handoff preflight, outcomes and provider identity."
  import Aiur.ControlCLI.Protocol, only: [guarded: 2, exit_marker: 1, error_marker: 0]
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Handoff.Report
  alias Aiur.Project.Supervisors

  @agents_contract "aiur.agents"
  @contract_version 1

  # Keep this below the 120s shell RPC envelope in engine/handoff.sh so the
  # daemon can report the blocked control RPC before the launcher times out.
  # Leave the prepare's 100s budget inside the shell's 120s RPC envelope.
  @preflight_snapshot_timeout_ms 10_000

  @spec print_latest(keyword()) :: :ok
  def print_latest(opts \\ []) do
    case Report.latest(opts) do
      {:ok, report} -> print(report)
      :none -> print(nil)
      {:error, reason} -> IO.puts("HANDOFF unavailable: #{inspect(reason)}")
    end
  end

  @spec prepare(keyword()) :: :ok
  def prepare(opts \\ []) do
    guarded("restart --keep-agents", fn ->
      timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, @preflight_snapshot_timeout_ms)
      snapshot_fun = Keyword.get(opts, :snapshot, fn -> Aiur.Orchestrator.snapshot(Aiur.Orchestrator.server(), timeout_ms) end)

      case snapshot_fun.() do
        :timeout ->
          failure("running daemon did not answer the handoff query within #{Aiur.ControlCLI.Protocol.format_timeout_budget(timeout_ms)} (control RPC blocked); retry the restart")

        :unavailable ->
          failure("orchestrator is not running")

        snapshot ->
          prepare_snapshot(snapshot, opts)
      end
    end)
  end

  defp prepare_snapshot(snapshot, opts) do
    running = Map.get(snapshot, :running, [])
    blocking = Enum.reject(running, &handoff_capable?/1)

    cond do
      running == [] ->
        prepare_running(opts)

      blocking == [] ->
        prepare_running(opts)

      length(blocking) == length(running) ->
        failure(blocking_message(blocking))

      true ->
        IO.puts("Handoff will not adopt #{count_phrase(blocking)}: #{backend_breakdown(blocking)}; they resume from their workspace after the restart")
        prepare_running(opts)
    end
  end

  # Which backends can hand a live session to the successor daemon is a
  # registry fact (`Aiur.CodingAgent.handoff_kind/1`), so a new backend cannot
  # be silently excluded by an allowlist here.
  defp handoff_capable?(agent), do: not is_nil(Aiur.CodingAgent.handoff_kind(Map.get(agent, :backend)))

  defp blocking_message(blocking) do
    "no running agent supports handoff: #{backend_breakdown(blocking)} cannot be adopted across a restart. " <>
      "Drain the fleet first (aiur pause --all, wait for those turns to end, then aiur stop and aiur run), " <>
      "or restart plainly without keep-agents: aiur restart"
  end

  defp count_phrase(agents), do: "#{length(agents)} #{if length(agents) == 1, do: "agent", else: "agents"}"

  defp backend_breakdown(agents) do
    agents
    |> Enum.group_by(&(Map.get(&1, :backend) || "unknown"))
    |> Enum.sort_by(fn {backend, group} -> {backend, -length(group)} end)
    |> Enum.map_join(", ", fn {backend, group} -> "#{backend} (#{count_phrase(group)})" end)
  end

  defp prepare_running(opts) do
    prepare_handoff = Keyword.get(opts, :handoff, fn -> Aiur.AgentControlCLI.prepare_handoff() end)

    case prepare_handoff.() do
      {:ok, result} ->
        IO.puts("__AIUR_HANDOFF__:#{result.handoff_id}")

        if result.skipped != [],
          do: IO.puts("Handoff skipped paused agents: #{Enum.join(result.skipped, ", ")}")

        for agent <- result.agents, reason = agent["fallback_reason"], not is_nil(reason) do
          IO.puts("Handoff ticket fallback: #{agent["identifier"]} (#{reason})")
        end

        exit_marker(0)

      {:error, reason} ->
        failure("handoff preflight failed: #{inspect(reason)}")
    end
  end

  @spec report(keyword()) :: :ok
  def report(opts \\ []) do
    guarded("status --handoff", fn ->
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, 0)

      case await_report(opts, deadline) do
        {:ok, report} ->
          print(report, opts)
          exit_marker(0)

        :none ->
          print(nil, opts)
          exit_marker(0)

        {:error, reason} ->
          failure("handoff report unavailable: #{inspect(reason)}")
      end
    end)
  end

  @spec agents(keyword()) :: :ok
  def agents(opts \\ []) do
    guarded("agents --json", fn ->
      snapshot = Keyword.get_lazy(opts, :snapshot, &Aiur.Orchestrator.snapshot/0)
      IO.puts(Jason.encode!(Map.merge(agents_payload(snapshot), Keyword.get_lazy(opts, :gateway, &gateway_facts/0))))
      exit_marker(0)
    end)
  end

  # A peer caches these to delegate here (`Aiur.Ownership.PeerState`); the ownership ref needs the daemon key.
  defp gateway_facts do
    key = with {:ok, key} <- Aiur.Identity.instance_key(), do: key
    served = if Process.whereis(Supervisors), do: for(%{repo: r, state: :running} <- Supervisors.which_projects(), do: r), else: []
    repos = List.wrap(GitHubConfig.repo()) ++ served
    %{daemon_key: if(is_binary(key), do: key), projects: repos |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase/1) |> Enum.uniq()}
  rescue
    # Unreadable facts are omitted, so the peer reads them as unknown; the agents list still answers.
    _ -> %{}
  end

  defp agents_payload(%{running: running}) when is_list(running) do
    rows =
      Enum.map(running, fn row ->
        row
        |> Map.take([:identifier, :issue_id, :session_id, :provider_pid, :codex_app_server_pid, :adopted_from])
        |> Map.put(:provider_pid, Report.provider_pid(row[:provider_pid] || row[:codex_app_server_pid]))
        # null, never an empty report, when the preload is unknown (e.g. an adopted session).
        |> Map.put(:skill_preload, row[:skill_preload])
      end)

    %{contract: @agents_contract, contract_version: @contract_version, running: rows}
  end

  @spec print(map() | nil, keyword()) :: :ok
  def print(report, opts \\ []) do
    cond do
      Keyword.get(opts, :json, false) ->
        IO.puts(Jason.encode!(report))

      is_nil(report) ->
        IO.puts("HANDOFF none")

      true ->
        IO.puts("HANDOFF #{report.handoff_id} at=#{report.completed_at || "unknown"} adopted=#{length(report.adopted)} fallback=#{length(report.fallback)} gap=#{report.gap_ms || "unknown"}ms")

        for agent <- report.adopted,
            do: IO.puts("#{agent["identifier"]} adopted pid=#{agent["provider_pid_after"]} session=#{agent["session_id_after"]}")

        for agent <- report.fallback,
            do: IO.puts("#{agent["identifier"]} fallback #{agent["reason"]}")
    end

    :ok
  end

  defp await_report(opts, deadline) do
    result = Report.latest(opts)
    expected = Keyword.get(opts, :expected_id)

    if is_nil(expected) or match?({:ok, %{handoff_id: ^expected}}, result) do
      result
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(100)
        await_report(opts, deadline)
      else
        {:error, :adoption_report_timeout}
      end
    end
  end

  defp failure(message) do
    IO.puts(error_marker() <> message)
    exit_marker(1)
  end
end
