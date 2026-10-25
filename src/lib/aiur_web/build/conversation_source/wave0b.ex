defmodule AiurWeb.Build.ConversationSource.Wave0b do
  @moduledoc "Temporary conversation adapter over workspace logs and the live projection."
  @behaviour AiurWeb.Build.ConversationSource

  alias Aiur.Conversation.History
  alias Aiur.Workspace.Layout
  alias AiurWeb.Build.ConversationSource.{Entries, Wave0bEvents}
  alias AiurWeb.EndpointConfig

  @impl true
  def prepare(%{id: id} = ref, opts) when is_binary(id) do
    if Regex.match?(~r/^[1-9][0-9]*$/, id) do
      prepare_valid(ref, opts)
    else
      {:error, :invalid_id}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def prepare(_, _), do: {:error, :invalid_id}

  defp prepare_valid(ref, opts) do
    case repository(ref) do
      :ok ->
        {:ok, running, fleet, unknown?} = running(ref.id, opts)
        workspace = if running, do: running[:workspace_path], else: nil
        workspace = workspace || Layout.issue_workspace_path(Aiur.Config.settings!().workspace.root, ref.id)
        remote? = running != nil and is_binary(running[:worker_host])
        reason = if remote?, do: nil, else: path_reason(workspace)
        handle = get_in(running || %{}, [:live_conversation, :generation_handle])

        {:ok,
         Map.merge(ref, %{
           prepared?: true,
           running: running,
           fleet: fleet,
           workspace: workspace,
           path: Path.join([workspace, "logs", "agent.ndjson"]),
           handle: handle,
           remote?: remote?,
           reason: reason,
           running_unknown?: unknown?
         })}

      {:error, reason} when reason in [:other_repository, :workspace_root_unknown] ->
        {:ok, Map.merge(ref, %{prepared?: true, running: nil, fleet: nil, path: nil, handle: nil, remote?: false, reason: reason})}
    end
  end

  @impl true
  def tail(ref, cursor, opts), do: read(ref, cursor, :tail, opts)

  @impl true
  def page(ref, cursor, opts) when is_binary(cursor), do: read(ref, cursor, :page, opts)
  def page(_, _, _), do: {:error, :invalid_cursor}

  @impl true
  def events(ref, opts), do: Wave0bEvents.read(ref, opts)

  @impl true
  def events_subscribe(identity, _opts), do: Wave0bEvents.subscribe(identity)

  @impl true
  def events_unsubscribe(topic, _opts), do: Wave0bEvents.unsubscribe(topic)

  @impl true
  def subscribe(ref, _opts), do: subscription(ref, :build_conversation_subscribe_fun, &History.live_subscribe/1)

  @impl true
  def unsubscribe(ref, _opts), do: subscription(ref, :build_conversation_unsubscribe_fun, &History.live_unsubscribe/1)

  defp subscription(%{handle: handle}, key, default) when is_binary(handle), do: safe(fn -> (EndpointConfig.get(key) || default).(handle) end)
  defp subscription(_, _, _), do: :ok

  defp read(ref, cursor, direction, opts) do
    with {:ok, ref} <- prepared(ref, opts) do
      cond do
        ref[:reason] -> {:ok, view(:unavailable, ref[:reason])}
        ref[:remote?] -> projection_view(ref, "remote_window")
        true -> local_view(ref, cursor, direction, opts)
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp prepared(%{prepared?: true} = ref, _), do: {:ok, ref}
  defp prepared(ref, opts), do: prepare(ref, opts)

  defp local_view(ref, cursor, direction, opts) do
    case path_reason(ref.workspace) do
      nil -> read_local(ref, cursor, direction, opts)
      reason -> {:ok, view(:unavailable, reason)}
    end
  end

  defp read_local(ref, cursor, direction, opts) do
    case read_page(ref.workspace, cursor, direction, opts) do
      {:ok, page} ->
        state = state(ref)
        entries = Entries.map_entries(page.entries, ref[:row] || %{}, direction == :tail and cursor == nil)
        {:ok, Map.merge(state, %{entries: entries, before: page.first, last: page.last, more?: page.more?})}

      {:error, :enoent} ->
        missing(ref)

      {:error, reason} when reason in [:invalid_cursor, :reset] ->
        {:error, reason}

      {:error, _} ->
        {:ok, Map.merge(state(ref), %{state: :unavailable, live?: false, reason: :unreadable})}
    end
  end

  defp read_page(workspace, nil, :tail, opts), do: History.workspace_paged_tail(workspace, opts)
  defp read_page(workspace, cursor, :tail, opts), do: History.workspace_paged_since(workspace, cursor, opts)
  defp read_page(workspace, cursor, :page, opts), do: History.workspace_paged_before(workspace, cursor, opts)

  defp missing(%{running: running} = ref) when is_map(running), do: projection_view(ref, "live_window")

  defp missing(ref) do
    legacy = Path.join([ref.workspace, "logs", "agent.md"])

    cond do
      ref[:running_unknown?] ->
        {:ok, view(:unavailable, :running_unknown)}

      File.regular?(legacy) ->
        log = History.workspace_log(ref.workspace)

        messages =
          log.messages
          |> Enum.reject(&legacy_placeholder?/1)
          |> Enum.with_index()
          |> Enum.map(fn {message, index} -> Map.put(message, :id, "legacy:#{index}") end)

        {:ok, Map.merge(view(:ended), %{entries: Entries.map_entries(messages, ref[:row] || %{}, true), note: "legacy_log"})}

      true ->
        {:ok, view(:not_retained)}
    end
  end

  defp legacy_placeholder?(message) do
    message[:body] in ["Agent log is empty.", "Agent log has not been written yet.", "No displayable chat events yet."]
  end

  defp projection_view(ref, note) do
    projection = projection(ref)
    messages = if projection[:state] == :unavailable, do: [], else: Map.get(projection, :messages, [])
    entries = Entries.projection(messages)
    note = if note == "live_window" and entries == [], do: nil, else: note
    {:ok, Map.merge(projection_state(ref, projection), %{entries: entries, note: note, evicted: Map.get(projection, :evicted_count, 0)})}
  end

  defp state(%{running_unknown?: true}), do: view(:unavailable, :running_unknown)
  defp state(%{running: nil}), do: view(:ended)
  defp state(ref), do: projection_state(ref, projection(ref))

  defp projection(ref) do
    result = safe(fn -> (EndpointConfig.get(:build_conversation_resolve_fun) || (&History.live_resolve/1)).(ref[:handle]) end)

    case result do
      {:ok, snapshot} when is_map(snapshot) -> snapshot
      snapshot when is_map(snapshot) -> snapshot
      _ -> %{state: :unavailable, reason: :unavailable}
    end
  end

  defp projection_state(ref, snapshot) do
    state = Map.get(snapshot, :state, :unavailable)
    state = if state in [:live, :ended, :known_empty, :stale, :unavailable, :restart_unknown], do: state, else: :unavailable
    Map.merge(view(state, snapshot[:reason]), %{live?: ref[:running] != nil and state in [:live, :known_empty], observed_at: snapshot[:observed_at]})
  end

  defp view(state, reason \\ nil), do: %{state: state, reason: reason, entries: [], before: nil, last: nil, more?: false, live?: false, observed_at: nil, note: nil, evicted: 0}

  defp running(id, opts) do
    result =
      safe(fn ->
        fun = EndpointConfig.get(:build_conversation_snapshot_fun) || (&Aiur.Orchestrator.dashboard_snapshot/2)
        fun.(Keyword.get(opts, :orchestrator, Aiur.Orchestrator), 2_000)
      end)

    case result do
      {_status, snapshot, _freshness} when is_map(snapshot) -> snapshot_running(snapshot, id)
      {:ok, snapshot} when is_map(snapshot) -> snapshot_running(snapshot, id)
      _ -> {:ok, nil, nil, true}
    end
  end

  defp snapshot_running(snapshot, id) do
    matches = Enum.filter(Map.get(snapshot, :running, []), &(to_string(&1[:identifier]) == id))
    all = matches ++ Enum.filter(Map.get(snapshot, :retrying, []) ++ Map.get(snapshot, :idle, []), &(to_string(&1[:identifier]) == id))

    if length(matches) <= 1 and length(Enum.uniq_by(all, & &1[:issue_id])) <= 1,
      do: {:ok, List.first(matches), %{fleet: snapshot}, false},
      else: {:ok, nil, %{fleet: snapshot}, true}
  end

  defp repository(ref) do
    case ref[:identity] do
      %{owner: owner, repository: repo} when is_binary(owner) and is_binary(repo) ->
        configured = Aiur.Tracker.workspace_repo_segment()

        cond do
          not is_binary(configured) -> {:error, :workspace_root_unknown}
          String.downcase(configured) == String.downcase(owner <> "/" <> repo) -> :ok
          true -> {:error, :other_repository}
        end

      _ ->
        :ok
    end
  end

  defp path_reason(workspace) do
    paths = [workspace, Path.join([workspace, "logs", "agent.ndjson"]), Path.join([workspace, "logs", "agent.md"])]

    Enum.find_value(paths, fn path ->
      case Layout.validate_workspace_path(path, nil) do
        :ok -> nil
        {:error, {reason, _, _}} -> reason
      end
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
