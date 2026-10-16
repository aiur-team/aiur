defmodule Aiur.Handoff.CLI do
  @moduledoc "CLI boundary for handoff preflight, outcomes and provider identity."
  import Aiur.ControlCLI.Protocol, only: [guarded: 2, exit_marker: 1, error_marker: 0]
  alias Aiur.Handoff.Report

  @spec print_latest(keyword()) :: :ok
  def print_latest(opts \\ []) do
    case Report.latest(opts) do
      {:ok, report} -> print(report)
      :none -> print(nil)
      {:error, reason} -> IO.puts("HANDOFF unavailable: #{inspect(reason)}")
    end
  end

  @spec prepare() :: :ok
  def prepare do
    guarded("restart --keep-agents", fn ->
      snapshot = Aiur.Orchestrator.snapshot()
      capable = Enum.any?(snapshot.running, &(&1[:backend] in ["codex", "claude", "claude-repl"]))

      if snapshot.running == [] or capable do
        prepare_running()
      else
        failure("no running agent supports handoff")
      end
    end)
  end

  defp prepare_running do
    case Aiur.AgentControlCLI.prepare_handoff() do
      {:ok, result} ->
        IO.puts("__AIUR_HANDOFF__:#{result.handoff_id}")
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
      rows = Enum.map(snapshot.running, &Map.take(&1, [:identifier, :issue_id, :session_id, :provider_pid, :codex_app_server_pid, :adopted_from]))
      rows = Enum.map(rows, &Map.put(&1, :provider_pid, Report.provider_pid(&1[:provider_pid] || &1[:codex_app_server_pid])))
      IO.puts(Jason.encode!(%{running: rows}))
      exit_marker(0)
    end)
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
        for agent <- report.adopted, do: IO.puts("#{agent["identifier"]} adopted pid=#{agent["provider_pid_after"]} session=#{agent["session_id_after"]}")
        for agent <- report.fallback, do: IO.puts("#{agent["identifier"]} fallback #{agent["reason"]}")
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
