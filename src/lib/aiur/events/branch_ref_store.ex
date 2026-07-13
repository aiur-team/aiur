defmodule Aiur.Events.BranchRefStore do
  @moduledoc """
  Owns restart-durable validated remote refs and pending final unblocks.

  Branch-push events update the ref baseline immediately. A final unblock that
  arrives before its matching ref is retained until the exact ref/SHA is later
  observed, preserving the agent's one-shot emission across event reordering.
  `LsRemoteTicker` also replaces the baseline after every successful poll,
  including its silent bootstrap.
  """

  use GenServer

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Events.GithubKeys
  alias Aiur.JsonStore

  @type metadata :: %{ref: String.t(), sha: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record(String.t(), String.t(), GenServer.server()) :: :ok | :error
  def record(ref, sha, server \\ __MODULE__)

  def record(ref, sha, server) when is_binary(ref) and is_binary(sha) do
    GenServer.call(server, {:record, ref, sha})
  end

  def record(_ref, _sha, _server), do: :error

  @doc """
  Records a branch ref and returns a pending final unblock for the exact same
  ref/SHA, if one arrived first. The unblock remains durable until routing
  acknowledges it after consumers actually resume.
  """
  @spec record_and_ready_unblock(String.t(), String.t(), GenServer.server()) ::
          {:ok, metadata() | nil} | :error
  def record_and_ready_unblock(ref, sha, server \\ __MODULE__)

  def record_and_ready_unblock(ref, sha, server) when is_binary(ref) and is_binary(sha) do
    GenServer.call(server, {:record_and_ready_unblock, ref, sha})
  end

  def record_and_ready_unblock(_ref, _sha, _server), do: :error

  @doc """
  Registers a final unblock. Returns `:ready` when its exact ref is already
  corroborated, otherwise durably retains it and returns `:pending`.
  """
  @spec register_unblock(String.t(), String.t(), GenServer.server()) :: :ready | :pending | :error
  def register_unblock(ref, sha, server \\ __MODULE__)

  def register_unblock(ref, sha, server) when is_binary(ref) and is_binary(sha) do
    GenServer.call(server, {:register_unblock, ref, sha})
  end

  def register_unblock(_ref, _sha, _server), do: :error

  @spec ready_unblock(String.t() | integer(), GenServer.server()) :: metadata() | nil
  def ready_unblock(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:ready_unblock, to_string(identifier)})
  end

  @spec acknowledge_unblock(String.t(), String.t(), GenServer.server()) :: :ok | :error
  def acknowledge_unblock(ref, sha, server \\ __MODULE__)

  def acknowledge_unblock(ref, sha, server) when is_binary(ref) and is_binary(sha) do
    GenServer.call(server, {:acknowledge_unblock, ref, sha})
  end

  def acknowledge_unblock(_ref, _sha, _server), do: :error

  @spec replace(map(), GenServer.server()) :: :ok
  def replace(refs, server \\ __MODULE__) when is_map(refs) do
    GenServer.call(server, {:replace, refs})
  end

  @spec latest(String.t() | integer(), GenServer.server()) :: metadata() | nil
  def latest(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:latest, to_string(identifier)})
  end

  @doc false
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    case store_path(opts) do
      {:ok, path} ->
        document = load(path)

        {:ok,
         %{
           path: path,
           refs: document.refs,
           pending_unblocks: document.pending_unblocks,
           persisted: document
         }}

      {:error, reason} ->
        Logger.error("BranchRefStore state path unavailable: reason=#{inspect(reason)}")
        {:stop, {:decision_state_dir_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:record, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        next = state |> Map.put(:refs, Map.put(state.refs, identifier, metadata)) |> persist_if_dirty()
        {:reply, :ok, next}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:record_and_ready_unblock, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        next =
          state
          |> Map.put(:refs, Map.put(state.refs, identifier, metadata))
          |> persist_if_dirty()

        {:reply, {:ok, get_pending(next.pending_unblocks, identifier, metadata)}, next}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:register_unblock, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        if Map.get(state.refs, identifier) == metadata do
          {:reply, :ready, persist_if_dirty(state)}
        else
          pending_unblocks = put_pending(state.pending_unblocks, identifier, metadata)
          {:reply, :pending, state |> Map.put(:pending_unblocks, pending_unblocks) |> persist_if_dirty()}
        end

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:ready_unblock, identifier}, _from, state) do
    ready =
      case Map.get(state.refs, identifier) do
        %{} = metadata -> get_pending(state.pending_unblocks, identifier, metadata)
        nil -> nil
      end

    {:reply, ready, state}
  end

  def handle_call({:acknowledge_unblock, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        {_pending, pending_unblocks} = pop_pending(state.pending_unblocks, identifier, metadata)
        {:reply, :ok, state |> Map.put(:pending_unblocks, pending_unblocks) |> persist_if_dirty()}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:replace, refs}, _from, state) do
    next = state |> Map.put(:refs, validated_refs(refs)) |> persist_if_dirty()
    {:reply, :ok, next}
  end

  def handle_call({:latest, identifier}, _from, state) do
    {:reply, Map.get(state.refs, identifier), state}
  end

  def handle_call(:reset, _from, state) do
    next = state |> Map.put(:refs, %{}) |> Map.put(:pending_unblocks, %{}) |> persist_if_dirty()
    {:reply, :ok, next}
  end

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, value} when is_map(value) -> decode_document(value)
      {:error, reason} -> log_load_failure(path, reason)
      _other -> empty_document()
    end
  end

  defp decode_document(value) do
    if Map.has_key?(value, "refs") or Map.has_key?(value, :refs) do
      refs = Map.get(value, "refs") || Map.get(value, :refs) || %{}
      pending_unblocks = Map.get(value, "pending_unblocks") || Map.get(value, :pending_unblocks) || %{}

      %{
        refs: decode_refs(refs),
        pending_unblocks: decode_pending_unblocks(pending_unblocks)
      }
    else
      # Migration from the first store format, whose top-level map was refs.
      %{refs: decode_refs(value), pending_unblocks: %{}}
    end
  end

  defp decode_refs(refs) do
    Enum.reduce(refs, %{}, fn
      {identifier, metadata}, acc when is_map(metadata) ->
        case decode_metadata(identifier, metadata) do
          {:ok, validated} -> Map.put(acc, identifier, validated)
          :error -> acc
        end

      _invalid, acc ->
        acc
    end)
  end

  defp decode_pending_unblocks(pending) when is_map(pending) do
    Enum.reduce(pending, %{}, &decode_pending_unblock/2)
  end

  defp decode_pending_unblocks(_pending), do: %{}

  defp decode_pending_unblock({identifier, entries}, pending) when is_map(entries) do
    validated = Enum.reduce(entries, %{}, &decode_pending_metadata(identifier, &1, &2))
    if map_size(validated) == 0, do: pending, else: Map.put(pending, identifier, validated)
  end

  defp decode_pending_unblock(_invalid, pending), do: pending

  defp decode_pending_metadata(identifier, {_key, metadata}, entries) when is_map(metadata) do
    case decode_metadata(identifier, metadata) do
      {:ok, value} -> Map.put(entries, pending_key(value), value)
      :error -> entries
    end
  end

  defp decode_pending_metadata(_identifier, _invalid, entries), do: entries

  defp decode_metadata(identifier, metadata) do
    ref = Map.get(metadata, "ref") || Map.get(metadata, :ref)
    sha = Map.get(metadata, "sha") || Map.get(metadata, :sha)

    case validated_entry(ref, sha) do
      {:ok, ^identifier, validated} -> {:ok, validated}
      _ -> :error
    end
  end

  defp persist_if_dirty(state) do
    document = current_document(state)

    if document == state.persisted do
      state
    else
      JsonStore.write!(state.path, document)
      %{state | persisted: document}
    end
  rescue
    error ->
      Logger.warning("BranchRefStore persistence failed: path=#{state.path} reason=#{Exception.message(error)}")
      state
  end

  defp current_document(state), do: %{refs: state.refs, pending_unblocks: state.pending_unblocks}
  defp empty_document, do: %{refs: %{}, pending_unblocks: %{}}

  defp log_load_failure(path, reason) do
    Logger.warning("BranchRefStore load failed: path=#{path} reason=#{inspect(reason)}")
    empty_document()
  end

  defp store_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} -> {:ok, path}
      :error -> default_path()
    end
  end

  defp default_path do
    case Paths.decision_state_dir() do
      {:ok, state_dir} -> {:ok, Path.join(state_dir, "branch_refs.json")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_pending(pending, identifier, metadata) do
    Map.update(pending, identifier, %{pending_key(metadata) => metadata}, fn entries ->
      Map.put(entries, pending_key(metadata), metadata)
    end)
  end

  defp pop_pending(pending, identifier, metadata) do
    entries = Map.get(pending, identifier, %{})
    {matched, remaining} = Map.pop(entries, pending_key(metadata))

    pending =
      if map_size(remaining) == 0,
        do: Map.delete(pending, identifier),
        else: Map.put(pending, identifier, remaining)

    {matched, pending}
  end

  defp get_pending(pending, identifier, metadata) do
    pending |> Map.get(identifier, %{}) |> Map.get(pending_key(metadata))
  end

  defp pending_key(metadata), do: metadata.ref <> ":" <> metadata.sha

  defp validated_refs(refs) do
    refs
    |> Enum.reduce(%{}, &put_validated_ref/2)
    |> Map.reject(fn {_identifier, metadata} -> metadata == :ambiguous end)
  end

  defp put_validated_ref({ref, sha}, refs) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} -> Map.update(refs, identifier, metadata, fn _ -> :ambiguous end)
      :error -> refs
    end
  end

  defp validated_entry(ref, sha) do
    with true <- valid_sha?(sha),
         {:ticket, identifier, _topic} <- GithubKeys.ref_to_topic(ref) do
      {:ok, identifier, %{ref: ref, sha: String.downcase(sha)}}
    else
      _ -> :error
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/i, sha)
end
