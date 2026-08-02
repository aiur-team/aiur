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

  @persist_retry_initial_ms 50
  @persist_retry_max_ms 1_000

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

  @spec replace(map(), GenServer.server()) :: :ok | :error
  def replace(refs, server \\ __MODULE__) when is_map(refs) do
    GenServer.call(server, {:replace, refs})
  end

  @spec latest(String.t() | integer(), GenServer.server()) :: metadata() | nil
  def latest(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:latest, to_string(identifier)})
  end

  @doc false
  @spec reset(GenServer.server()) :: :ok | :error
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc """
  Blocks until any persistence retry queued by a prior write has resolved.

  Writes reply as soon as their own attempt either lands or gets queued for
  retry (see `@persist_retry_initial_ms`/`@persist_retry_max_ms`), so a
  caller that needs the eventual outcome of a write that returned `:error`
  under transient disk pressure — not just this write's immediate result —
  has no signal to wait on otherwise. This waits on the actual retry
  succeeding rather than guessing at a wall-clock deadline.
  """
  @spec await_settled(GenServer.server(), timeout()) :: :ok
  def await_settled(server \\ __MODULE__, timeout \\ 10_000),
    do: GenServer.call(server, :await_settled, timeout)

  @impl true
  def init(opts) do
    with {:ok, path} <- store_path(opts),
         {:ok, document} <- load(path) do
      {:ok,
       %{
         path: path,
         refs: document.refs,
         pending_unblocks: document.pending_unblocks,
         persisted: document,
         pending_persist: nil,
         persist_retry_ref: nil,
         persist_retry_token: nil,
         persist_retry_delay_ms: @persist_retry_initial_ms,
         settle_waiters: []
       }}
    else
      {:error, {:load_failed, reason}} ->
        Logger.error("BranchRefStore state load failed: reason=#{inspect(reason)}")
        {:stop, {:state_load_failed, reason}}

      {:error, reason} ->
        Logger.error("BranchRefStore state path unavailable: reason=#{inspect(reason)}")
        {:stop, {:decision_state_dir_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:record, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        candidate = desired_state(state)
        candidate |> Map.put(:refs, Map.put(candidate.refs, identifier, metadata)) |> persist_reply(:ok)

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:record_and_ready_unblock, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        candidate = desired_state(state)
        next = Map.put(candidate, :refs, Map.put(candidate.refs, identifier, metadata))
        reply = {:ok, get_pending(next.pending_unblocks, identifier, metadata)}
        persist_reply(next, reply)

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:register_unblock, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        candidate = desired_state(state)
        pending_unblocks = put_pending(candidate.pending_unblocks, identifier, metadata)
        candidate = Map.put(candidate, :pending_unblocks, pending_unblocks)
        reply = if Map.get(candidate.refs, identifier) == metadata, do: :ready, else: :pending
        persist_reply(candidate, reply)

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
        candidate = desired_state(state)
        {_pending, pending_unblocks} = pop_pending(candidate.pending_unblocks, identifier, metadata)
        candidate |> Map.put(:pending_unblocks, pending_unblocks) |> persist_reply(:ok)

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:replace, refs}, _from, state) do
    state |> desired_state() |> Map.put(:refs, validated_refs(refs)) |> persist_reply(:ok)
  end

  def handle_call({:latest, identifier}, _from, state) do
    {:reply, Map.get(state.refs, identifier), state}
  end

  def handle_call(:reset, _from, state) do
    state
    |> desired_state()
    |> Map.put(:refs, %{})
    |> Map.put(:pending_unblocks, %{})
    |> persist_reply(:ok)
  end

  def handle_call(:await_settled, _from, %{persist_retry_ref: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_settled, from, state) do
    {:noreply, %{state | settle_waiters: [from | state.settle_waiters]}}
  end

  @impl true
  def handle_info({:retry_persist, token}, %{persist_retry_token: token} = state) do
    candidate = state |> Map.put(:persist_retry_ref, nil) |> Map.put(:persist_retry_token, nil) |> desired_state()

    case persist_if_dirty(candidate) do
      {:ok, persisted} -> {:noreply, persisted}
      {:error, queued} -> {:noreply, queued}
    end
  end

  def handle_info({:retry_persist, _stale_token}, state), do: {:noreply, state}

  defp persist_reply(candidate, success_reply) do
    case persist_if_dirty(candidate) do
      {:ok, persisted} -> {:reply, success_reply, persisted}
      {:error, original} -> {:reply, :error, original}
    end
  end

  defp desired_state(%{pending_persist: %{} = document} = state) do
    %{state | refs: document.refs, pending_unblocks: document.pending_unblocks}
  end

  defp desired_state(state), do: state

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, value} when is_map(value) ->
        case decode_document(value) do
          {:ok, document} -> {:ok, document}
          {:error, reason} -> {:error, {:load_failed, {:invalid_document, reason}}}
        end

      {:ok, _invalid} ->
        {:error, {:load_failed, :invalid_document}}

      {:error, reason} ->
        {:error, {:load_failed, reason}}
    end
  end

  defp decode_document(value) do
    if document_format?(value) do
      with refs when is_map(refs) <- field(value, "refs", %{}),
           pending when is_map(pending) <- field(value, "pending_unblocks", %{}),
           {:ok, decoded_refs} <- decode_refs(refs),
           {:ok, decoded_pending} <- decode_pending_unblocks(pending) do
        {:ok, %{refs: decoded_refs, pending_unblocks: decoded_pending}}
      else
        _ -> {:error, :invalid_fields}
      end
    else
      # Migration from the first store format, whose top-level map was refs.
      case decode_refs(value) do
        {:ok, refs} -> {:ok, %{refs: refs, pending_unblocks: %{}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp document_format?(value) do
    Map.has_key?(value, "refs") or Map.has_key?(value, :refs) or
      Map.has_key?(value, "pending_unblocks") or Map.has_key?(value, :pending_unblocks)
  end

  defp field(value, "refs", default), do: Map.get(value, "refs", Map.get(value, :refs, default))

  defp field(value, "pending_unblocks", default),
    do: Map.get(value, "pending_unblocks", Map.get(value, :pending_unblocks, default))

  defp decode_refs(refs) do
    Enum.reduce_while(refs, {:ok, %{}}, fn
      {identifier, metadata}, {:ok, acc} when is_binary(identifier) and is_map(metadata) ->
        case decode_metadata(identifier, metadata) do
          {:ok, validated} -> {:cont, {:ok, Map.put(acc, identifier, validated)}}
          :error -> {:halt, {:error, :invalid_ref}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_ref}}
    end)
  end

  defp decode_pending_unblocks(pending) when is_map(pending) do
    Enum.reduce_while(pending, {:ok, %{}}, &decode_pending_unblock/2)
  end

  defp decode_pending_unblock({identifier, entries}, {:ok, pending})
       when is_binary(identifier) and is_map(entries) do
    case Enum.reduce_while(entries, {:ok, %{}}, &decode_pending_metadata(identifier, &1, &2)) do
      {:ok, validated} -> {:cont, {:ok, Map.put(pending, identifier, validated)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp decode_pending_unblock(_invalid, _pending), do: {:halt, {:error, :invalid_pending_unblock}}

  defp decode_pending_metadata(identifier, {_key, metadata}, {:ok, entries}) when is_map(metadata) do
    case decode_metadata(identifier, metadata) do
      {:ok, value} -> {:cont, {:ok, Map.put(entries, pending_key(value), value)}}
      :error -> {:halt, {:error, :invalid_pending_metadata}}
    end
  end

  defp decode_pending_metadata(_identifier, _invalid, _entries),
    do: {:halt, {:error, :invalid_pending_metadata}}

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
      {:ok, clear_retry(state)}
    else
      case write_document(state.path, document) do
        :ok ->
          {:ok, clear_retry(%{state | persisted: document})}

        {:error, error} ->
          Logger.warning("BranchRefStore persistence failed: path=#{state.path} reason=#{Exception.message(error)}")

          {:error, queue_retry(state, document)}
      end
    end
  end

  defp write_document(path, document) do
    JsonStore.write!(path, document)
    :ok
  rescue
    error -> {:error, error}
  end

  defp queue_retry(state, document) do
    state = rollback(state)

    if state.persist_retry_ref do
      %{state | pending_persist: document}
    else
      token = make_ref()
      timer_ref = Process.send_after(self(), {:retry_persist, token}, state.persist_retry_delay_ms)
      next_delay = min(state.persist_retry_delay_ms * 2, @persist_retry_max_ms)

      %{
        state
        | pending_persist: document,
          persist_retry_ref: timer_ref,
          persist_retry_token: token,
          persist_retry_delay_ms: next_delay
      }
    end
  end

  defp clear_retry(state) do
    if state.persist_retry_ref, do: Process.cancel_timer(state.persist_retry_ref)

    Enum.each(state.settle_waiters, &GenServer.reply(&1, :ok))

    %{
      state
      | pending_persist: nil,
        persist_retry_ref: nil,
        persist_retry_token: nil,
        persist_retry_delay_ms: @persist_retry_initial_ms,
        settle_waiters: []
    }
  end

  defp rollback(state) do
    %{state | refs: state.persisted.refs, pending_unblocks: state.persisted.pending_unblocks}
  end

  defp current_document(state), do: %{refs: state.refs, pending_unblocks: state.pending_unblocks}

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
