defmodule Aiur.BuildOrder.History.Feeder do
  @moduledoc "Maintains history from existing inputs and bounded recovery."
  use GenServer
  require Logger
  alias Aiur.BuildOrder.History
  alias Aiur.BuildOrder.History.{CatchUp, Feed, Row, TelemetryScan}
  alias Aiur.GitHub.{ResourceEvents, ResourceStore, Transport, ViewStateSweep}
  alias Aiur.Webhooks.ModeRegistry
  alias AiurWeb.ObservabilityPubSub
  @types [:issue, :issue_labels, :issue_dependency, :sub_issue]
  # ponytail: hourly recovery and one-second merge debounce; tune only after measuring.
  @signal_window_ms 3_600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec offer_open_issues(String.t(), String.t(), list(), DateTime.t()) :: :ok
  def offer_open_issues(owner, repo, issues, at), do: GenServer.cast(__MODULE__, {:open_listing, owner, repo, issues, at})
  @spec catch_up_status(GenServer.server()) :: map() | {:error, :not_running}
  def catch_up_status(server \\ __MODULE__) do
    GenServer.call(server, :catch_up_status)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @impl true
  def init(opts) do
    repo =
      case Keyword.get(opts, :repo_fun, &Transport.parse_repo/0).() do
        {:ok, {owner, repo}} -> String.downcase(owner <> "/" <> repo)
        _other -> nil
      end

    if repo do
      Enum.each(@types, &ResourceEvents.subscribe(&1, repo))
      History.subscribe()
      ObservabilityPubSub.subscribe()
      ModeRegistry.subscribe_recovered()
      ViewStateSweep.subscribe_diverged()
    end

    state = %{
      repo: repo,
      history: [server: Keyword.get(opts, :history, History)],
      opts: opts,
      now: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      catch_task: nil,
      telemetry_task: nil,
      pending?: false,
      window_timer: nil,
      last_start: nil,
      merge_timer: nil,
      version_warned?: false,
      resource_timer: nil,
      changes: %{},
      refused: MapSet.new(),
      complete?: false,
      status: %{status: :not_backfilled, at: nil, reason: nil, pages: 0, watermark: nil}
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, %{repo: nil} = state), do: {:noreply, state}

  def handle_continue(:boot, state) do
    changes = for type <- @types, {key, _body} <- ResourceStore.list_type(type, state.repo), do: %{key: key, resource_type: type, source: :resource_store}
    state = state |> apply_resources(changes) |> scan_merges()
    path = Keyword.get_lazy(state.opts, :telemetry_path, &Aiur.RunTelemetry.telemetry_file/0)
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> TelemetryScan.dispatches(path) end)
    state = %{state | telemetry_task: task.ref, complete?: History.health(state.history).complete?}
    {:noreply, request_catch_up(state)}
  end

  @impl true
  def handle_call(:catch_up_status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast({:open_listing, owner, repo, issues, at}, state) do
    events = if same_repo?(state, owner <> "/" <> repo), do: Feed.listing(rows(state), issues, at), else: []
    {:noreply, apply_events(state, events)}
  end

  @impl true
  def handle_info({:github_resource_changed, %{data?: true} = change}, state) do
    if change.resource_type in @types and same_repo?(state, change.owner <> "/" <> change.repo) do
      timer = state.resource_timer || Process.send_after(self(), :apply_resources, 10)
      {:noreply, %{state | resource_timer: timer, changes: Map.put(state.changes, change.key, change)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:apply_resources, state) do
    state = apply_resources(state, Map.values(state.changes))
    {:noreply, %{state | resource_timer: nil, changes: %{}}}
  end

  def handle_info({:observability_updated, _id}, state) do
    {:noreply, %{state | merge_timer: state.merge_timer || Process.send_after(self(), :scan_merges, 1_000)}}
  end

  def handle_info(:scan_merges, state), do: {:noreply, scan_merges(%{state | merge_timer: nil})}

  def handle_info({:build_order_history_changed, %{health: health}}, state) do
    completed? = health.complete? and not state.complete?
    state = %{state | complete?: health.complete?}
    {:noreply, if(completed?, do: request_catch_up(state), else: state)}
  end

  def handle_info({signal, repo}, state) when signal in [:webhook_recovered, :view_state_diverged] do
    {:noreply, if(same_repo?(state, repo), do: request_catch_up(state), else: state)}
  end

  def handle_info(:catch_up_window, state), do: {:noreply, request_catch_up(%{state | window_timer: nil, pending?: false})}

  def handle_info({ref, result}, %{catch_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = finish_catch_up(%{state | catch_task: nil}, result)
    {:noreply, if(state.pending? or result.status == :partial, do: pending(state), else: state)}
  end

  def handle_info({ref, dispatches}, %{telemetry_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    events = Enum.map(dispatches, fn {n, at} -> Feed.event(n, %{dispatched_at: at}, state.now.(), :telemetry) end)
    {:noreply, apply_events(%{state | telemetry_task: nil}, events)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{catch_task: ref} = state) do
    result = %{status: :failed, at: state.now.(), reason: {:task_down, reason}, pages: 0, watermark: nil, events: []}
    state = finish_catch_up(%{state | catch_task: nil}, result)
    {:noreply, if(state.pending?, do: pending(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{telemetry_task: ref} = state) do
    Logger.warning("aiur_build_history_feed telemetry_scan_failed reason=#{inspect(reason)}")
    {:noreply, %{state | telemetry_task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp rows(state) do
    case History.snapshot(state.history) do
      {:ok, snapshot} -> snapshot.rows
      {:error, _health} -> %{}
    end
  end

  defp rows(state, numbers) do
    case History.rows(Enum.uniq(Enum.reject(numbers, &is_nil/1)), state.history) do
      {:ok, rows, _health} -> Map.new(rows, &{&1.number, &1})
      {:error, _health} -> %{}
    end
  end

  defp apply_resources(state, changes) do
    now = state.now.()
    changes = Enum.sort_by(changes, &Enum.find_index(@types, fn type -> type == &1.resource_type end))

    observations =
      Enum.flat_map(changes, fn change ->
        case ResourceStore.fetch(change.key) do
          {:ok, entry} -> [{change, entry}]
          :miss -> []
        end
      end)

    state = warn_invalid_version(state, observations)

    numbers =
      Enum.flat_map(observations, fn {change, entry} ->
        values = if is_map(entry.data), do: Map.take(entry.data, ["number", "blocked_issue_number", "parent_issue_number", "sub_issue_number"]) |> Map.values(), else: []
        Enum.map([elem(change.key, 3) | values], &Feed.number/1)
      end)

    {events, _rows} =
      Enum.reduce(observations, {[], rows(state, numbers)}, fn {change, entry}, {events, held} ->
        source = if Map.get(change, :source) == :webhook, do: :webhook, else: :resource_store
        produced = resource_events(change, entry.data, entry, held, state.repo, now, source)
        {events ++ produced, merge_rows(held, produced)}
      end)

    apply_events(state, events)
  end

  defp warn_invalid_version(%{version_warned?: true} = state, _observations), do: state

  defp warn_invalid_version(state, observations) do
    invalid? =
      Enum.any?(observations, fn
        {%{resource_type: :issue}, entry} -> Feed.date(entry.data["updated_at"]) == :unknown
        {%{resource_type: :issue_labels}, entry} -> Feed.date(entry.version) == :unknown
        _other -> false
      end)

    if invalid?, do: Logger.warning("aiur_build_history_feed invalid_updated_at repository=#{state.repo}")
    %{state | version_warned?: invalid?}
  end

  defp resource_events(%{resource_type: :issue}, body, _entry, held, _repo, now, source), do: Feed.issue(Map.get(held, Feed.number(body["number"])), body, now, source)

  defp resource_events(%{resource_type: :issue_labels, key: {_, _, _, id}}, body, entry, held, _repo, now, source) do
    case Feed.number(id) do
      nil -> []
      n -> Feed.labels(Map.get(held, n), n, body, entry.version, now, source)
    end
  end

  defp resource_events(%{resource_type: :issue_dependency}, body, entry, held, repo, now, source),
    do: Feed.dependency(Map.get(held, Feed.number(body["blocked_issue_number"])), Map.put(body, "edge_version", entry.version), repo, now, source)

  defp resource_events(%{resource_type: :sub_issue}, body, entry, held, repo, now, source),
    do: Feed.sub_issue(Map.get(held, Feed.number(body["sub_issue_number"])), Map.merge(body, %{"joined_at" => entry.version, "edge_version" => entry.version}), repo, now, source)

  defp merge_rows(rows, events) do
    Enum.reduce(events, rows, fn event, rows ->
      case Row.merge(Map.get(rows, event.number), event) do
        {:changed, row} -> Map.put(rows, event.number, row)
        :unchanged -> rows
      end
    end)
  end

  defp scan_merges(%{repo: nil} = state), do: state

  defp scan_merges(state) do
    merges = Aiur.RecentMergeStore.list(Keyword.get(state.opts, :merge_store, Aiur.RecentMergeStore))
    held = rows(state, Enum.map(merges, &Feed.number(&1.ticket_id)))
    events = Enum.flat_map(merges, &Feed.merge(Map.get(held, Feed.number(&1.ticket_id)), &1, state.repo, state.now.()))

    apply_events(state, events)
  end

  defp apply_events(state, []), do: state

  defp apply_events(state, events) do
    case History.apply(events, state.history) do
      {:ok, _result} -> state
      {:error, reason} -> refused(state, reason)
    end
  end

  defp refused(state, reason) do
    unless MapSet.member?(state.refused, reason), do: Logger.warning("aiur_build_history_feed apply_refused reason=#{inspect(reason)}")
    %{state | refused: MapSet.put(state.refused, reason)}
  end

  defp request_catch_up(%{repo: nil} = state), do: state

  defp request_catch_up(state) do
    health = History.health(state.history)

    with true <- health.state == :healthy and health.complete?,
         {:ok, closed} <- History.checkpoint(:closed_since, state.history),
         {:ok, backfill} <- History.checkpoint(:backfill, state.history),
         %DateTime{} = floor <- CatchUp.floor(closed, backfill) do
      if state.catch_task || remaining_window(state) > 0 do
        pending(state)
      else
        start_catch_up(state, floor, closed)
      end
    else
      failure ->
        reason = if failure == :unknown, do: :no_floor, else: health.failure
        finish_catch_up(state, %{status: :not_backfilled, at: state.now.(), reason: reason, pages: 0, watermark: nil, events: []})
    end
  end

  defp start_catch_up(state, floor, closed) do
    opts = state.opts ++ [continuation: (closed || %{})["continuation"]]
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> CatchUp.run(state.repo, floor, opts) end)
    %{state | catch_task: task.ref, last_start: System.monotonic_time(:millisecond), pending?: false, status: %{state.status | status: :running, at: state.now.(), reason: nil}}
  end

  defp remaining_window(%{last_start: nil}), do: 0
  defp remaining_window(state), do: max(0, @signal_window_ms - (System.monotonic_time(:millisecond) - state.last_start))
  defp pending(%{catch_task: ref} = state) when not is_nil(ref), do: %{state | pending?: true}
  defp pending(state), do: %{state | window_timer: state.window_timer || Process.send_after(self(), :catch_up_window, remaining_window(state)), pending?: true}

  defp finish_catch_up(state, result) do
    previous =
      case History.checkpoint(:closed_since, state.history) do
        {:ok, checkpoint} -> checkpoint || %{}
        {:error, _reason} -> %{}
      end

    {status, checkpoint} = catch_up_checkpoint(result, previous)
    held = rows(state, Enum.map(result.events, & &1.number))

    events =
      Enum.map(result.events, fn event ->
        diff = Feed.label_fields(Map.get(held, event.number), Map.get(event.fields, :labels), Map.get(event.fields, :updated_at))
        Feed.protect_edges(Map.get(held, event.number), %{event | fields: Map.merge(event.fields, diff)})
      end)

    case History.apply(events, state.history ++ [checkpoint: {:closed_since, checkpoint}]) do
      {:ok, _result} -> %{state | status: status}
      {:error, reason} -> %{refused(state, reason) | status: %{status | status: :failed, reason: {:apply_refused, reason}, watermark: state.status.watermark}}
    end
  end

  defp catch_up_checkpoint(result, previous) do
    watermark = result.watermark || Feed.date(previous["watermark"])
    status = result |> Map.drop([:events, :continuation]) |> Map.put(:watermark, if(watermark == :unknown, do: nil, else: watermark))
    checkpoint = %{"watermark" => iso(status.watermark), "status" => Atom.to_string(status.status), "at" => iso(status.at), "reason" => format_reason(status.reason), "pages" => status.pages}
    continuation = Map.get(result, :continuation) || retained_continuation(result.status, previous)
    {status, Map.put(checkpoint, "continuation", continuation)}
  end

  defp retained_continuation(status, previous) when status in [:failed, :held], do: previous["continuation"]
  defp retained_continuation(_status, _previous), do: nil
  defp format_reason(nil), do: nil
  defp format_reason(reason), do: inspect(reason)

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil
  defp same_repo?(state, repo), do: is_binary(repo) and state.repo == String.downcase(repo)
end
