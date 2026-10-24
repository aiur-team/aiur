defmodule Aiur.Handoff do
  @moduledoc "Quiesces a daemon and durably hands its live provider sessions to its successor."

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff.{Protection, Record}
  alias Aiur.Orchestrator.State
  alias Aiur.ProcessReaper
  alias Aiur.RunTelemetry.RunContext

  @prepare_timeout_ms 100_000
  @finalize_reserve_ms 5_000

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

    values =
      {config.tracker.kind, config.tracker.github.repo, config.tracker.linear.project_slug, config.workspace.root, config.worker.ssh_hosts}

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
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :prepare_timeout_ms, @prepare_timeout_ms)

    case call_with_deadline(server, :prepare_handoff_snapshot, deadline, @finalize_reserve_ms) do
      {:ok, state} ->
        prepare_entries(owner, server, opts, deadline, state)

      {:error, reason} ->
        cancel_dispatch(server)
        {:error, reason}
    end
  end

  defp prepare_entries(owner, server, opts, deadline, state) do
    all_entries = Enum.filter(state.running, fn {_id, entry} -> is_pid(entry[:pid]) end)
    skipped = Enum.filter(all_entries, fn {_id, entry} -> State.paused_running_entry?(entry) end)
    entries = Enum.reject(all_entries, fn {_id, entry} -> State.paused_running_entry?(entry) end)
    hold = Keyword.get(opts, :hold, &RunnerHandoff.hold/1)

    outcome =
      try do
        Enum.each(entries, fn {_id, entry} -> hold.(entry.pid) end)

        with {:ok, quiesce_timeout} <- remaining_timeout(deadline, @finalize_reserve_ms),
             :ok <-
               ToolCallLedger.quiesce(
                 min(Keyword.get(opts, :tool_timeout_ms, 60_000), quiesce_timeout),
                 Keyword.get(opts, :ledger, ToolCallLedger)
               ),
             {:ok, snapshots} <- snapshots(entries, opts, deadline),
             {:ok, refreshed} <- call_with_deadline(server, :prepare_handoff_snapshot, deadline),
             {:ok, agents} <- materialize_snapshots(snapshots, refreshed, deadline),
             record = record(agents, opts),
             :ok <- Record.write(record, opts) do
          survivors = Enum.filter(agents, &is_nil(&1["fallback_reason"]))

          tickets =
            survivors
            |> Enum.flat_map(&[&1["issue_id"], &1["identifier"]])
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&to_string/1)
            |> MapSet.new()

          refs =
            Enum.flat_map(survivors, &transport_refs/1) ++
              for {ref, :agent, meta} <- ProcessReaper.entries(),
                  MapSet.member?(tickets, to_string(meta[:ticket])),
                  do: ref

          :ok = ProcessReaper.handoff(refs)

          result = %{
            path: Record.path(opts),
            handoff_id: record["handoff_id"],
            agents: agents,
            skipped: Enum.map(skipped, fn {_id, entry} -> entry.identifier end)
          }

          Protection.store(owner, result, tickets)
          {:ok, result}
        end
      rescue
        error -> {:error, {:prepare_exception, error}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case outcome do
      {:ok, _result} = success ->
        success

      {:error, _reason} = error ->
        abort = Keyword.get(opts, :abort, &RunnerHandoff.abort/1)

        Enum.each(all_entries, fn {_id, entry} ->
          try do
            abort.(entry.pid)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        cancel_dispatch(server)
        error
    end
  end

  defp transport_refs(%{"transport" => transport}) do
    pids =
      for key <- ~w(relay_pid provider_pid os_pid),
          pid = transport[key],
          is_integer(pid) and pid > 0,
          do: {:os_pid, pid}

    case transport do
      %{"pane_id" => pane, "socket" => socket} when is_binary(pane) and is_binary(socket) ->
        [{:pane, pane, socket} | pids]

      _ ->
        pids
    end
  end

  defp transport_refs(_), do: []

  defp snapshots(entries, opts, prepare_deadline) do
    snapshot = Keyword.get(opts, :snapshot, &RunnerHandoff.snapshot/1)
    timeout = Keyword.get(opts, :snapshot_timeout_ms, 65_000)
    deadline = min(System.monotonic_time(:millisecond) + timeout, prepare_deadline - @finalize_reserve_ms)

    pending =
      entries
      |> Enum.map(fn {id, entry} ->
        parent = self()
        ref = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            result = snapshot_agent(entry, snapshot)
            send(parent, {ref, result})
          end)

        {id, entry, ref, pid, monitor}
      end)

    results =
      Enum.map(pending, fn {id, entry, ref, pid, monitor} ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        result =
          receive do
            {^ref, value} ->
              Process.demonitor(monitor, [:flush])
              value

            {:DOWN, ^monitor, :process, ^pid, reason} ->
              {:error, {:runner_gone, reason}}
          after
            remaining ->
              Process.exit(pid, :kill)
              Process.demonitor(monitor, [:flush])
              {:error, :snapshot_timeout}
          end

        {id, entry, result}
      end)

    Enum.reduce_while(results, {:ok, []}, fn {id, entry, result}, {:ok, snapshots} ->
      case result do
        {:ok, agent} ->
          {:cont, {:ok, [{id, entry, {:ok, agent}} | snapshots]}}

        {:error, reason} ->
          case snapshot_fallback_reason(reason) do
            nil ->
              {:halt, {:error, {id, reason}}}

            fallback ->
              abort = Keyword.get(opts, :abort, &RunnerHandoff.abort/1)
              abort.(entry.pid)
              {:cont, {:ok, [{id, entry, {:fallback, fallback}} | snapshots]}}
          end
      end
    end)
  end

  defp materialize_snapshots(snapshots, state, deadline) do
    agents =
      Enum.map(snapshots, fn {id, entry, result} ->
        entry = Map.get(state.running, id, entry)
        metadata = snapshot_metadata(id, entry, state)

        case result do
          {:ok, agent} ->
            Map.merge(metadata, agent)

          {:fallback, reason} ->
            Map.merge(metadata, %{
              "backend" => get_in(entry, [:session_execution, :backend]) || "unknown",
              "workspace" => entry[:workspace_path],
              "transport" => %{"kind" => "unsupported"},
              "fallback_reason" => reason
            })
        end
      end)

    if System.monotonic_time(:millisecond) < deadline,
      do: {:ok, agents},
      else: {:error, :handoff_deadline}
  end

  defp remaining_timeout(deadline, reserve_ms) do
    case deadline - System.monotonic_time(:millisecond) - reserve_ms do
      timeout when timeout > 0 -> {:ok, timeout}
      _ -> {:error, :handoff_deadline}
    end
  end

  defp call_with_deadline(server, message, deadline, reserve_ms \\ 0) do
    with {:ok, timeout} <- remaining_timeout(deadline, reserve_ms) do
      try do
        {:ok, GenServer.call(server, message, timeout)}
      catch
        :exit, reason -> {:error, {:orchestrator_call_failed, reason}}
      end
    end
  end

  defp cancel_dispatch(server) do
    try do
      GenServer.call(server, :cancel_handoff, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end

  defp snapshot_metadata(id, entry, state) do
    %{
      "issue_id" => id,
      "identifier" => entry.issue.identifier,
      "worker_host" => entry[:worker_host],
      "issue" => json_value(entry.issue),
      "running_entry" => RunnerHandoff.encode(Map.drop(entry, [:pid, :ref])),
      "started_at" => entry[:started_at],
      "retry_state" => RunnerHandoff.encode(Map.get(state.retry_attempts, id)),
      "dispatch_attempts" => RunnerHandoff.encode(get_in(state.dispatch_recovery, [:codex_thrash_budget, id]))
    }
  end

  defp snapshot_fallback_reason(:snapshot_timeout), do: "snapshot_timeout"
  defp snapshot_fallback_reason({:runner_gone, _reason}), do: "runner_gone"
  defp snapshot_fallback_reason(_reason), do: nil

  defp snapshot_agent(entry, snapshot) do
    case get_in(entry, [:session_execution, :backend]) do
      backend when backend in [nil, "codex", "claude", "claude-repl"] ->
        snapshot.(entry.pid)

      backend ->
        {:ok,
         %{
           "backend" => backend,
           "workspace" => entry[:workspace_path],
           "transport" => %{"kind" => "unsupported"},
           "fallback_reason" => "relay_protocol"
         }}
    end
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%MapSet{} = value), do: Enum.map(value, &json_value/1)
  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

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
