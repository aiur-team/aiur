defmodule Aiur.Events.Export.Exporter do
  @moduledoc "Single writer for the optional, sequenced external event journal."
  # aiur:event-bus-boundary-member
  use GenServer
  require Logger
  alias Aiur.Events.{Catalog, Envelope, Export, InstanceId, Journal}
  alias Aiur.Events.Export.Layout

  # RQ-4 / #6322: census pending; then max(1_000, 10 * larger peak/minute).
  @backlog_threshold 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      state: :starting,
      reason: nil,
      instance: nil,
      epoch: nil,
      oldest_seq: nil,
      head_seq: nil,
      opts: opts,
      dropped: 0,
      dir: nil,
      path: nil,
      last_at: nil,
      backlog_raised?: false,
      backlog_checks: 0,
      backlog_timer: nil
    }

    publish_status(state)
    {:ok, schedule_backlog_check(state), {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    {:noreply, boot(state)}
  end

  defp boot(state) do
    identity = Keyword.get(state.opts, :identity, &InstanceId.current/0)
    directory = Keyword.get(state.opts, :directory, &Layout.directory/0)

    with {:ok, instance} <- identity.(),
         {:ok, dir} <- directory.() do
      prepare(%{state | instance: instance, dir: dir})
    else
      {:error, :identity_unavailable} -> unavailable(state, :identity_unavailable)
      _ -> unavailable(state, :runtime_dir_unavailable)
    end
  rescue
    _ -> unavailable(state, :append_failed)
  end

  defp prepare(state) do
    path =
      case List.last(Layout.segments(state.dir)) do
        nil -> Layout.segment(state.dir, 1)
        {_, path} -> path
      end

    with :ok <- Journal.prepare(state.dir, path),
         {:ok, recovered} <- Layout.recover(state.dir, state.instance),
         :ok <- Journal.prepare(state.dir, recovered.path) do
      state = Map.merge(state, recovered)
      state = trim(%{state | state: :available})
      catalog = Keyword.get(state.opts, :catalog, Catalog)
      subscribe = Keyword.get(state.opts, :subscribe, &Aiur.Events.subscribe/1)
      patterns = catalog.exported() |> Enum.map(& &1.pattern) |> Enum.uniq()
      # Broader catalog entries already cover their specific exported children.
      patterns = Enum.reject(patterns, fn pattern -> Enum.any?(patterns, &(&1 != pattern and Aiur.Events.matches?(&1, pattern))) end)
      Enum.each(patterns, fn pattern -> :ok = subscribe.(pattern) end)
      gap = %{"type" => "gap", "scope" => "*", "reason" => "exporter_start", "from" => state.last_at, "to" => DateTime.to_iso8601(DateTime.utc_now())}
      append(%{state | state: :available}, gap)
    else
      {:error, :journal_corrupt} -> unavailable(state, :journal_corrupt)
      _ -> unavailable(state, :runtime_dir_unavailable)
    end
  end

  @impl true
  def handle_info({:event, event}, %{state: :available} = state) do
    case Envelope.to_external(event, instance: state.instance, catalog: Keyword.get(state.opts, :catalog, Catalog)) do
      :skip -> {:noreply, state}
      {:ok, envelope} -> {:noreply, append(state, Map.put(envelope, "type", "event"))}
    end
  end

  def handle_info(:check_backlog, state) do
    Process.cancel_timer(state.backlog_timer)
    {:noreply, state |> check_backlog() |> schedule_backlog_check()}
  end

  def handle_info({:event, _}, state), do: {:noreply, %{state | dropped: state.dropped + 1}}
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_backlog_check(state) do
    timer = Process.send_after(self(), :check_backlog, Keyword.get(state.opts, :backlog_check_interval, 5_000))
    %{state | backlog_timer: timer}
  end

  defp check_backlog(%{state: :available} = state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    threshold = Keyword.get(state.opts, :backlog_threshold, @backlog_threshold)
    crossing? = if state.backlog_raised?, do: len * 2 < threshold, else: len > threshold
    checks = if crossing?, do: state.backlog_checks + 1, else: 0

    if checks == 2 do
      raised? = not state.backlog_raised?
      Keyword.get(state.opts, :on_backlog, fn _, _ -> :ok end).(if(raised?, do: :raised, else: :cleared), %{len: len, threshold: threshold})
      %{state | backlog_raised?: raised?, backlog_checks: 0}
    else
      %{state | backlog_checks: checks}
    end
  end

  defp check_backlog(state), do: %{state | backlog_checks: 0}

  defp append(state, record) do
    record = Map.put(record, "seq", state.head_seq + 1)
    append_fun = Keyword.get(state.opts, :append, &Journal.append/2)

    with {:ok, state} <- roll(state, record),
         :ok <- append_fun.(state.path, record) do
      state = %{state | head_seq: record["seq"], last_at: record["observed_at"] || record["to"]}
      Layout.write_meta(state.dir, state)
      publish_status(state)
      Keyword.get(state.opts, :on_appended, fn _, _ -> :ok end).(state.head_seq, state.epoch)
      state
    else
      _ -> unavailable(state, :append_failed)
    end
  rescue
    _ -> unavailable(state, :append_failed)
  end

  defp roll(state, record) do
    with {:ok, stat} <- File.stat(state.path) do
      size = byte_size(Jason.encode!(record)) + 1

      cond do
        size > Layout.max_bytes() ->
          {:error, :record_too_large}

        stat.size + size <= Layout.max_bytes() ->
          {:ok, state}

        true ->
          new_segment(state)
      end
    end
  end

  defp new_segment(state) do
    path = Layout.segment(state.dir, state.head_seq + 1)
    with :ok <- Journal.prepare(state.dir, path), do: {:ok, trim(%{state | path: path})}
  end

  defp trim(state) do
    {paths, state} =
      Layout.trim!(Layout.segment_info!(state.dir), %{
        meta: state,
        now: Keyword.get(state.opts, :now, &DateTime.utc_now/0).(),
        retention_days: Keyword.get(state.opts, :retention_days, Aiur.Config.events_export_retention_days()),
        retention_max_events: Keyword.get(state.opts, :retention_max_events, Aiur.Config.events_export_retention_max_events())
      })

    Layout.write_meta(state.dir, state)
    publish_status(state)
    unlink = Keyword.get(state.opts, :unlink, &File.rm/1)

    Enum.each(paths, fn path ->
      case unlink.(path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Export retention unlink failed path=#{path} reason=#{inspect(reason)}")
      end
    end)

    state
  end

  defp unavailable(%{state: :unavailable} = state, _), do: state

  defp unavailable(state, reason) do
    state = %{state | state: :unavailable, reason: reason}
    publish_status(state)
    Keyword.get(state.opts, :on_unavailable, fn _ -> :ok end).(reason)
    state
  end

  defp publish_status(state) do
    status = Map.take(state, [:state, :reason, :instance, :epoch, :oldest_seq, :head_seq])
    status = if status.state == :starting, do: %{status | state: :unavailable}, else: status
    :persistent_term.put({Export, :status}, status)
  end

  @impl true
  def terminate(_, _), do: :persistent_term.erase({Export, :status})
end
