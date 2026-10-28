defmodule Aiur.Conversation.SubjectIndex do
  @moduledoc """
  Cached index from durable conversation subjects to their conversation ids.

  Invalid or unreadable subject records are skipped and counted in a warning,
  so a partially written folder cannot hide healthy records.
  """

  use GenServer
  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Conversation.Ref
  alias Aiur.TrackerIdentity

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec lookup(TrackerIdentity.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found | :ambiguous | :unavailable}
  def lookup(identity, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case GenServer.call(server, {:lookup, TrackerIdentity.github_key(identity)}) do
      {:ok, id} -> {:ok, id}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec lookup_or_live(TrackerIdentity.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found | :ambiguous | :unavailable}
  def lookup_or_live(identity, opts \\ []) do
    case live_match(identity, Keyword.get(opts, :snapshot_fun, &dashboard_snapshot/0)) do
      {:ok, id} -> {:ok, id}
      :not_found -> lookup(identity, opts)
    end
  catch
    :exit, _ -> lookup(identity, opts)
  end

  defp dashboard_snapshot do
    case Aiur.Orchestrator.dashboard_snapshot() do
      {status, %{running: running}, _freshness} when status in [:current, :stale] and is_list(running) ->
        {:ok, running}

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp live_match(identity, snapshot_fun) do
    key = TrackerIdentity.github_key(identity)

    case snapshot_fun.() do
      {:ok, running} when is_list(running) ->
        case Enum.find(running, &(TrackerIdentity.github_key(Map.get(&1, :tracker_identity)) == key)) do
          %{tracker_identity: match} ->
            case Ref.worker(match) do
              {:ok, ref} -> {:ok, Ref.conversation_id(ref)}
              _ -> :not_found
            end

          _ ->
            :not_found
        end

      _ ->
        :not_found
    end
  end

  @spec index(keyword()) :: {:ok, map()} | {:error, :unavailable}
  def index(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :index)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec invalidate(keyword()) :: :ok
  def invalidate(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, :invalidate)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    {:ok, %{root_fun: Keyword.get(opts, :root_fun, &Paths.conversation_state_dir/0), scan_fun: Keyword.get(opts, :scan_fun, &scan/1), snapshot: nil}}
  end

  @impl true
  def handle_call({:lookup, nil}, _from, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:lookup, key}, _from, state) do
    case current_index(state) do
      {index, state} ->
        result =
          case Map.get(index, key, []) do
            [id] -> {:ok, id}
            [] -> {:error, :not_found}
            _ -> {:error, :ambiguous}
          end

        {:reply, result, state}

      {:error, :unavailable, state} ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(:index, _from, state) do
    case current_index(state) do
      {index, state} -> {:reply, {:ok, index}, state}
      {:error, :unavailable, state} -> {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_cast(:invalidate, state), do: {:noreply, %{state | snapshot: nil}}

  defp current_index(%{snapshot: {index, _bad_count}} = state), do: {index, state}

  defp current_index(state) do
    case state.root_fun.() do
      {:ok, root} ->
        case state.scan_fun.(root) do
          {:ok, index, bad_count} ->
            if bad_count > 0 do
              Logger.warning("Conversation subject index skipped #{bad_count} unreadable subject.json file(s)")
            end

            {index, %{state | snapshot: {index, bad_count}}}

          {:error, _reason} ->
            {:error, :unavailable, state}
        end

      {:error, _reason} ->
        {:error, :unavailable, state}
    end
  end

  defp scan(root) do
    case File.ls(root) do
      {:ok, dirs} ->
        {index, bad_count} =
          Enum.reduce(dirs, {%{}, 0}, fn name, {index, bad_count} ->
            dir = Path.join(root, name)

            case read_subject(dir) do
              {:ok, id, key} -> {Map.update(index, key, [id], &[id | &1]), bad_count}
              :skip -> {index, bad_count + 1}
            end
          end)

        {:ok, index, bad_count}

      {:error, :enoent} ->
        {:ok, %{}, 0}

      error ->
        error
    end
  end

  defp read_subject(dir) do
    path = Path.join(dir, "subject.json")

    with true <- File.dir?(dir),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"v" => 1, "kind" => "worker", "conversation_id" => id, "owner" => owner, "repository" => repository, "provider_id" => provider_id}} <- Jason.decode(bytes),
         {:ok, ref} <- Ref.worker(identity(owner, repository, provider_id)),
         true <- Ref.conversation_id(ref) == id and Path.basename(dir) == id do
      {:ok, id, TrackerIdentity.github_key(identity(owner, repository, provider_id))}
    else
      false -> :skip
      {:error, _} -> :skip
      _ -> :skip
    end
  rescue
    _ -> :skip
  end

  defp identity(owner, repository, provider_id) do
    %TrackerIdentity{status: :joinable, kind: :github, owner: owner, repository: repository, provider_id: provider_id, identifier: "1", reason: nil}
  end
end
