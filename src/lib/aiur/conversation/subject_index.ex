defmodule Aiur.Conversation.SubjectIndex do
  @moduledoc """
  Cached index from durable conversation subjects to their conversation ids.

  Invalid or unreadable subject records are skipped and counted in a warning,
  so a partially written folder cannot hide healthy records.
  """

  use GenServer
  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Conversation.{HistoryReader, Ref, StoreFiles}
  alias Aiur.TrackerIdentity

  @table :aiur_conversation_subjects

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec lookup(TrackerIdentity.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :ambiguous | :unavailable}
  def lookup(identity, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case GenServer.call(server, {:lookup, TrackerIdentity.github_key(identity)}) do
      {:ok, id} -> {:ok, id}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec lookup_or_live(TrackerIdentity.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :ambiguous | :unavailable}
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
        running
        |> Enum.find(&(TrackerIdentity.github_key(Map.get(&1, :tracker_identity)) == key))
        |> live_match_result()

      _ ->
        :not_found
    end
  end

  defp live_match_result(%{tracker_identity: match}) do
    case Ref.worker(match) do
      {:ok, ref} -> {:ok, Ref.conversation_id(ref)}
      _ -> :not_found
    end
  end

  defp live_match_result(_), do: :not_found

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
    GenServer.call(server, :invalidate)
  catch
    :exit, _ -> :ok
  end

  @doc "Updates the legacy issue-number index and invalidates the cached identity index."
  @spec put(Path.t(), Ref.t()) :: :ok
  def put(dir, %Ref{subject: {:worker, identity}} = ref) do
    id = Ref.conversation_id(ref)

    if :ets.whereis(@table) != :undefined do
      key = {Path.dirname(dir), String.downcase(identity.owner), String.downcase(identity.repository), identity.identifier, id}
      :ets.insert(@table, {key, true})
    end

    invalidate()
  end

  def put(_dir, _ref), do: :ok

  @doc "Resolves the legacy owner/repository/issue-number key."
  @spec resolve(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()} | {:error, :ambiguous_subject, [String.t()]}
  def resolve(owner, repository, identifier) do
    with {:ok, root} <- Paths.conversation_state_dir(),
         true <- :ets.whereis(@table) != :undefined,
         :ok <- load(root) do
      ids =
        :ets.match(
          @table,
          {{root, String.downcase(owner), String.downcase(repository), identifier, :"$1"}, true}
        )
        |> List.flatten()
        |> Enum.sort()

      readable(ids)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp readable(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case HistoryReader.snapshot(id) do
        {:ok, _} -> {:cont, {:ok, [id | acc]}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :not_found}
      {:ok, [id]} -> {:ok, id}
      {:ok, ids} -> {:error, :ambiguous_subject, Enum.sort(ids)}
      error -> error
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       root_fun: Keyword.get(opts, :root_fun, &Paths.conversation_state_dir/0),
       scan_fun: Keyword.get(opts, :scan_fun, &scan/1),
       snapshot: nil
     }}
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

  def handle_call(:invalidate, _from, state), do: {:reply, :ok, %{state | snapshot: nil}}

  defp current_index(%{snapshot: {index, _bad_count}} = state), do: {index, state}

  defp current_index(state) do
    with {:ok, root} <- state.root_fun.(),
         {:ok, index, bad_count} <- state.scan_fun.(root) do
      log_bad_count(bad_count)
      {index, %{state | snapshot: {index, bad_count}}}
    else
      {:error, _reason} -> {:error, :unavailable, state}
    end
  end

  defp log_bad_count(count) when count > 0,
    do: Logger.warning("Conversation subject index skipped #{count} unreadable subject.json file(s)")

  defp log_bad_count(_count), do: :ok

  defp scan(root) do
    case File.ls(root) do
      {:ok, dirs} ->
        {index, bad_count} = Enum.reduce(dirs, {%{}, 0}, &add_subject(root, &1, &2))
        {:ok, index, bad_count}

      {:error, :enoent} ->
        {:ok, %{}, 0}

      error ->
        error
    end
  end

  defp add_subject(root, name, {index, bad_count}) do
    case read_subject(Path.join(root, name)) do
      {:ok, id, key} -> {Map.update(index, key, [id], &[id | &1]), bad_count}
      :skip -> {index, bad_count + 1}
      :ignore -> {index, bad_count}
    end
  end

  defp read_subject(dir) do
    unless File.dir?(dir), do: throw(:ignore)

    path = Path.join(dir, "subject.json")

    case File.read(path) do
      {:ok, bytes} -> read_subject_record(dir, bytes)
      {:error, _} -> :skip
    end
  rescue
    _ -> :skip
  catch
    :ignore -> :ignore
  end

  defp read_subject_record(dir, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"v" => 1, "kind" => "executor", "conversation_id" => id}} when is_binary(id) ->
        :ignore

      {:ok,
       %{
         "v" => 1,
         "kind" => "worker",
         "conversation_id" => id,
         "owner" => owner,
         "repository" => repository,
         "provider_id" => provider_id
       }} ->
        read_worker_subject(dir, id, owner, repository, provider_id)

      _ ->
        :skip
    end
  end

  defp read_worker_subject(dir, id, owner, repository, provider_id) do
    subject_identity = identity(owner, repository, provider_id)

    with {:ok, ref} <- Ref.worker(subject_identity),
         true <- Ref.conversation_id(ref) == id and Path.basename(dir) == id do
      {:ok, id, TrackerIdentity.github_key(subject_identity)}
    else
      _ -> :skip
    end
  end

  defp identity(owner, repository, provider_id) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: "1",
      reason: nil
    }
  end

  defp load(root) do
    if :ets.member(@table, {:loaded, root}) do
      :ok
    else
      with :ok <- StoreFiles.check(root),
           {:ok, names} <- directories(root) do
        bad_count = load_names(root, names)
        :ets.insert(@table, {{:loaded, root}, true})
        log_bad_count(bad_count)
        :ok
      end
    end
  end

  defp directories(root) do
    case File.ls(root) do
      {:error, :enoent} -> {:ok, []}
      result -> result
    end
  end

  defp load_names(root, names) do
    names
    |> Enum.filter(&Regex.match?(~r/\Aconv_[a-z2-7]{26}\z/, &1))
    |> Enum.reduce(0, fn name, bad_count ->
      if load_name(root, name), do: bad_count, else: bad_count + 1
    end)
  end

  defp load_name(root, name) do
    dir = Path.join(root, name)

    with :ok <- StoreFiles.check(dir),
         {:ok, bytes} <- File.read(Path.join(dir, "subject.json")),
         {:ok, subject} <- Jason.decode(bytes) do
      index_subject(dir, subject) == :ok
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp index_subject(_dir, %{"v" => 1, "kind" => "executor"}), do: :ok

  defp index_subject(dir, %{"v" => 1, "kind" => "worker"} = subject) do
    subject_identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      reason: nil,
      owner: subject["owner"],
      repository: subject["repository"],
      identifier: subject["identifier"],
      provider_id: subject["provider_id"]
    }

    with {:ok, ref} <- Ref.worker(subject_identity),
         true <- Ref.conversation_id(ref) == subject["conversation_id"] and Path.basename(dir) == subject["conversation_id"] do
      put(dir, ref)
    else
      _ -> {:error, :invalid_subject}
    end
  end

  defp index_subject(_dir, _subject), do: {:error, :invalid_subject}
end
