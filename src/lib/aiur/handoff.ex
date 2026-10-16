defmodule Aiur.Handoff do
  @moduledoc "Quiesces a daemon and durably hands its live provider sessions to its successor."

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff.{Protection, Record}
  alias Aiur.ProcessReaper
  alias Aiur.RunTelemetry.RunContext

  @spec prepare(keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(opts \\ []) do
    server = Keyword.get(opts, :orchestrator, Aiur.Orchestrator)
    owner = GenServer.whereis(server)
    :global.trans({{__MODULE__, owner}, self()}, fn -> prepare_once(owner, server, opts) end)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @spec hold_dispatch(map()) :: {:reply, map(), map()}
  def hold_dispatch(state) do
    Process.put({__MODULE__, :dispatch_hold}, true)
    {:reply, state, state}
  end

  @doc false
  @spec release_dispatch(map()) :: {:reply, :ok, map()}
  def release_dispatch(state) do
    Process.delete({__MODULE__, :dispatch_hold})
    {:reply, :ok, state}
  end

  @spec dispatch_held?() :: boolean()
  def dispatch_held?, do: Process.get({__MODULE__, :dispatch_hold}, false)

  @doc false
  @spec claim_or_empty(map(), (-> term())) :: term()
  def claim_or_empty(state, claim) do
    if dispatch_held?(), do: {:reply, :empty, state}, else: claim.()
  end

  @spec active?() :: boolean()
  defdelegate active?(), to: Protection
  @spec reset() :: :ok
  defdelegate reset(), to: Protection
  @spec protected?(term()) :: boolean()
  defdelegate protected?(identifier), to: Protection

  @spec config_fingerprint() :: String.t()
  def config_fingerprint do
    {:ok, config} = Aiur.Config.settings()
    values = {config.tracker.kind, config.tracker.github.repo, config.tracker.linear.project_slug, config.workspace.root, config.worker.ssh_hosts}
    :crypto.hash(:sha256, :erlang.term_to_binary(values)) |> Base.encode16(case: :lower)
  end

  defp prepare_once(owner, server, opts) do
    case Protection.prepared() do
      %{owner: ^owner, result: result} -> {:ok, result}
      _ -> do_prepare(owner, server, opts)
    end
  end

  defp do_prepare(owner, server, opts) do
    opts = Keyword.put_new_lazy(opts, :config_fingerprint, &config_fingerprint/0)
    state = GenServer.call(server, :prepare_handoff_snapshot, 65_000)
    entries = Enum.filter(state.running, fn {_id, entry} -> is_pid(entry[:pid]) end)
    hold = Keyword.get(opts, :hold, &RunnerHandoff.hold/1)
    Enum.each(entries, fn {_id, entry} -> hold.(entry.pid) end)

    with :ok <- ToolCallLedger.quiesce(Keyword.get(opts, :tool_timeout_ms, 60_000), Keyword.get(opts, :ledger, ToolCallLedger)),
         {:ok, agents} <- snapshots(entries, server, opts),
         record = record(agents, opts),
         :ok <- Record.write(record, opts) do
      survivors = Enum.filter(agents, &is_nil(&1["fallback_reason"]))
      tickets = survivors |> Enum.flat_map(&[&1["issue_id"], &1["identifier"]]) |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1) |> MapSet.new()

      refs =
        Enum.flat_map(survivors, &transport_refs/1) ++
          for {ref, :agent, meta} <- ProcessReaper.entries(), MapSet.member?(tickets, to_string(meta[:ticket])), do: ref

      :ok = ProcessReaper.handoff(refs)
      result = %{path: Record.path(opts), handoff_id: record["handoff_id"], agents: agents}
      Protection.store(owner, result, tickets)
      {:ok, result}
    else
      {:error, _} = error ->
        abort = Keyword.get(opts, :abort, &RunnerHandoff.abort/1)
        Enum.each(entries, fn {_id, entry} -> abort.(entry.pid) end)
        GenServer.call(server, :cancel_handoff)
        error
    end
  end

  defp transport_refs(%{"transport" => transport}) do
    pids = for key <- ~w(relay_pid provider_pid os_pid), pid = transport[key], is_integer(pid) and pid > 0, do: {:os_pid, pid}

    case transport do
      %{"pane_id" => pane, "socket" => socket} when is_binary(pane) and is_binary(socket) -> [{:pane, pane, socket} | pids]
      _ -> pids
    end
  end

  defp transport_refs(_), do: []

  defp snapshots(entries, server, opts) do
    snapshot = Keyword.get(opts, :snapshot, &RunnerHandoff.snapshot/1)

    Enum.reduce_while(entries, {:ok, []}, fn {id, entry}, {:ok, agents} ->
      case snapshot_agent(entry, snapshot) do
        {:ok, agent} ->
          state = GenServer.call(server, :prepare_handoff_snapshot, 65_000)
          entry = Map.get(state.running, id, entry)

          metadata = %{
            "issue_id" => id,
            "identifier" => entry.issue.identifier,
            "worker_host" => entry[:worker_host],
            "issue" => json_value(entry.issue),
            "running_entry" => RunnerHandoff.encode(Map.drop(entry, [:pid, :ref])),
            "started_at" => entry[:started_at],
            "retry_state" => RunnerHandoff.encode(Map.get(state.retry_attempts, id)),
            "dispatch_attempts" => RunnerHandoff.encode(get_in(state.dispatch_recovery, [:codex_thrash_budget, id]))
          }

          {:cont, {:ok, [Map.merge(metadata, agent) | agents]}}

        {:error, reason} ->
          {:halt, {:error, {id, reason}}}
      end
    end)
  end

  defp snapshot_agent(entry, snapshot) do
    case get_in(entry, [:session_execution, :backend]) do
      backend when backend in [nil, "codex", "claude", "claude-repl"] -> snapshot.(entry.pid)
      backend -> {:ok, %{"backend" => backend, "workspace" => entry[:workspace_path], "transport" => %{"kind" => "unsupported"}, "fallback_reason" => "relay_protocol"}}
    end
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%MapSet{} = value), do: Enum.map(value, &json_value/1)
  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()
  defp json_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_reference(value) or is_pid(value) or is_function(value), do: nil
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value), do: value

  defp build_version do
    build = RunContext.build(%{})
    build.aiur_vsn <> "+" <> build.build_sha
  end

  defp record(agents, opts) do
    %{
      "handoff_schema" => 1,
      "handoff_id" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "from_version" => build_version(),
      "generation" => System.unique_integer([:positive]),
      "config_fingerprint" => Keyword.get_lazy(opts, :config_fingerprint, &config_fingerprint/0),
      "agents" => agents
    }
  end
end
