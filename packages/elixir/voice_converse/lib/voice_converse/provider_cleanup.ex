defmodule VoiceConverse.ProviderCleanup do
  @moduledoc """
  Deletes provider-side conversations only after their local transcript is durable.

  The append-only queue is stored beneath `transcript_root`, so a restart resumes unfinished
  deletions. Queue operations are synced before they are acknowledged. Hosts call `resume/1`
  after a credential changes to retry a queue paused for missing or refused credentials.
  """

  use GenServer

  alias VoiceConverse.Provider.ElevenLabsAgents.HTTP

  @queue_file "provider-cleanup.ndjson"
  @delete_endpoint "https://api.elevenlabs.io/v1/convai/conversations/"
  @retry_delays [30_000, 120_000, 600_000, 3_600_000, 21_600_000 | List.duplicate(86_400_000, 7)]
  @persistence_retry_delay 30_000

  @type server :: GenServer.server()

  @doc "Starts one serialized provider-cleanup queue."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Durably adds one provider conversation to the default cleanup queue."
  @spec enqueue(String.t(), String.t()) :: :ok | {:error, term()}
  def enqueue(provider_conversation_id, conversation_id),
    do: enqueue(__MODULE__, provider_conversation_id, conversation_id)

  @doc "Durably adds one provider conversation to `server`'s cleanup queue."
  @spec enqueue(server(), String.t(), String.t()) :: :ok | {:error, term()}
  def enqueue(server, provider_conversation_id, conversation_id) do
    GenServer.call(server, {:enqueue, provider_conversation_id, conversation_id})
  end

  @doc "Retries a queue paused because its credential was missing or refused."
  @spec resume(server()) :: :ok | {:error, term()}
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  @impl true
  def init(opts) do
    with {:ok, root} <- fetch_root(opts),
         {:ok, credentials} <- fetch_credentials(opts),
         :ok <- ensure_root(root),
         {:ok, pending, paused, skipped} <- read_queue(root) do
      state = %{
        root: root,
        credentials: credentials,
        http: Keyword.get(opts, :http, HTTP),
        scheduler: Keyword.get(opts, :scheduler, &schedule_after/1),
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        writer: Keyword.get(opts, :writer) || (&append/2),
        retry_delays: Keyword.get(opts, :retry_delays) || @retry_delays,
        pending: pending,
        paused: paused,
        scheduled?: false,
        auth_alerted?: paused == :provider_auth,
        skipped: skipped
      }

      {:ok, state, {:continue, :schedule}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:schedule, state) do
    if state.skipped > 0, do: telemetry(:queue_recovery, %{count: state.skipped})
    {:noreply, schedule(state, 0)}
  end

  @impl true
  def handle_call({:enqueue, provider_id, conversation_id}, _from, state) do
    with :ok <- valid_id(provider_id, :provider_conversation_id),
         :ok <- valid_id(conversation_id, :conversation_id),
         {:ok, item} <- append_enqueue(state, provider_id, conversation_id, 0, nil) do
      state = %{state | pending: Map.put(state.pending, provider_id, item)}
      {:reply, :ok, schedule(state, 0)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:resume, _from, state) do
    case resume_queue(state) do
      :ok -> {:reply, :ok, schedule(%{state | paused: nil, auth_alerted?: false}, 0)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:run_provider_cleanup, state) do
    {:noreply, state |> Map.put(:scheduled?, false) |> delete_next()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp delete_next(%{paused: paused} = state) when not is_nil(paused), do: state
  defp delete_next(%{pending: pending} = state) when map_size(pending) == 0, do: state

  defp delete_next(state) do
    {_provider_id, item} = Enum.min_by(state.pending, fn {_id, item} -> item.at end)

    case delete(state, item.provider_id) do
      {:ok, status} when status in 200..299 or status == 404 -> mark_done(state, item, status)
      {:ok, status} when status in [401, 403] -> pause_for_auth(state)
      {:error, :missing} -> %{state | paused: :unconfigured}
      _failure -> retry_or_give_up(state, item)
    end
  end

  defp mark_done(state, item, status) do
    case append_terminal(state, "done", item.provider_id, status) do
      :ok -> state |> Map.update!(:pending, &Map.delete(&1, item.provider_id)) |> schedule(0)
      {:error, _reason} -> retry_or_give_up(state, item)
    end
  end

  defp pause_for_auth(state) do
    unless state.auth_alerted?, do: telemetry(:auth_failure, %{count: 1})
    _ = append_queue_event(state, "provider_auth_paused")
    %{state | paused: :provider_auth, auth_alerted?: true}
  end

  defp retry_or_give_up(state, item) do
    case Enum.at(state.retry_delays, item.attempt) do
      nil ->
        case append_terminal(state, "gave_up", item.provider_id, "retry_budget_exhausted") do
          :ok ->
            telemetry(:give_up, %{count: 1})
            state |> Map.update!(:pending, &Map.delete(&1, item.provider_id)) |> schedule(0)

          {:error, _reason} ->
            schedule(state, @persistence_retry_delay)
        end

      delay ->
        with {:ok, updated} <- append_enqueue(state, item.provider_id, item.conversation_id, item.attempt + 1, item.at) do
          state
          |> Map.update!(:pending, &Map.put(&1, item.provider_id, updated))
          |> schedule(delay)
        else
          {:error, _reason} -> state |> update_pending_attempt(item) |> schedule(delay)
        end
    end
  end

  defp update_pending_attempt(state, item) do
    updated = %{item | attempt: item.attempt + 1}
    Map.update!(state, :pending, &Map.put(&1, item.provider_id, updated))
  end

  defp schedule(%{scheduled?: true} = state, _delay), do: state
  defp schedule(%{paused: paused} = state, _delay) when not is_nil(paused), do: state
  defp schedule(%{pending: pending} = state, _delay) when map_size(pending) == 0, do: state

  defp schedule(state, delay) do
    state.scheduler.(delay)
    %{state | scheduled?: true}
  end

  defp append_enqueue(state, provider_id, conversation_id, attempt, original_at) do
    at = original_at || iso8601(state.clock.())
    item = %{provider_id: provider_id, conversation_id: conversation_id, attempt: attempt, at: at}

    case write(state, Map.merge(%{"op" => "enqueue"}, stringify(item))) do
      :ok -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_terminal(state, op, provider_id, status) do
    write(state, %{"op" => op, "provider_id" => provider_id, "at" => iso8601(state.clock.()), "status" => status})
  end

  defp append_queue_event(state, op) do
    write(state, %{"op" => op, "at" => iso8601(state.clock.())})
  end

  defp resume_queue(%{paused: :provider_auth} = state), do: append_queue_event(state, "provider_auth_resumed")
  defp resume_queue(_state), do: :ok

  defp write(state, record), do: state.writer.(state.root, record)

  defp delete(state, provider_id) do
    with {:ok, key} <- fetch_credential(state.credentials),
         {:ok, status, _body} <-
           http_delete(state.http, @delete_endpoint <> URI.encode(provider_id, &URI.char_unreserved?/1),
             headers: [{"xi-api-key", key}],
             receive_timeout: 5_000
           ) do
      {:ok, status}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp fetch_credential({credentials, provider}) do
    case credentials.fetch(provider, :delete) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _otherwise -> {:error, :missing}
    end
  rescue
    _error -> {:error, :missing}
  catch
    _kind, _reason -> {:error, :missing}
  end

  defp http_delete(http, url, opts) when is_function(http, 2), do: http.(url, opts)
  defp http_delete(http, url, opts), do: http.delete(url, opts)

  defp read_queue(root) do
    with {:ok, path} <- queue_path(root) do
      case File.read(path) do
        {:ok, content} -> decode_queue(content)
        {:error, :enoent} -> {:ok, %{}, nil, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_queue(content) do
    {lines, tail} = split_lines(content)

    {pending, paused, skipped} =
      Enum.reduce(lines, {%{}, nil, if(tail == "", do: 0, else: 1)}, fn line, {pending, paused, skipped} ->
        case Jason.decode(line) do
          {:ok, record} -> apply_record(pending, paused, record, skipped)
          _otherwise -> {pending, paused, skipped + 1}
        end
      end)

    {:ok, pending, paused, skipped}
  end

  defp apply_record(
         pending,
         paused,
         %{"op" => "enqueue", "provider_id" => provider_id, "conversation_id" => conversation_id} = record,
         skipped
       )
       when is_binary(provider_id) and is_binary(conversation_id) do
    attempt = if is_integer(record["attempt"]) and record["attempt"] >= 0, do: record["attempt"], else: 0
    at = if is_binary(record["at"]), do: record["at"], else: ""

    {Map.put(pending, provider_id, %{
       provider_id: provider_id,
       conversation_id: conversation_id,
       attempt: attempt,
       at: at
     }), paused, skipped}
  end

  defp apply_record(pending, paused, %{"op" => op, "provider_id" => provider_id}, skipped)
       when op in ["done", "gave_up"] and is_binary(provider_id),
       do: {Map.delete(pending, provider_id), paused, skipped}

  defp apply_record(pending, _paused, %{"op" => "provider_auth_paused"}, skipped),
    do: {pending, :provider_auth, skipped}

  defp apply_record(pending, :provider_auth, %{"op" => "provider_auth_resumed"}, skipped),
    do: {pending, nil, skipped}

  defp apply_record(pending, paused, %{"op" => "provider_auth_resumed"}, skipped),
    do: {pending, paused, skipped}

  defp apply_record(pending, paused, _record, skipped), do: {pending, paused, skipped + 1}

  defp append(root, record) do
    with {:ok, path} <- queue_path(root),
         :ok <- ensure_root(root),
         {:ok, fd} <- open_queue(path) do
      result =
        with {:ok, line} <- Jason.encode(record),
             :ok <- :file.write(fd, line <> "\n"),
             :ok <- :file.datasync(fd) do
          :ok
        end

      case :file.close(fd) do
        :ok -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_queue(path) do
    case :file.open(path, [:read, :append, :binary, :raw, :exclusive]) do
      {:ok, fd} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, fd}

          {:error, reason} ->
            :ok = :file.close(fd)
            {:error, reason}
        end

      {:error, :eexist} ->
        open_existing_queue(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %File.Stat{type: :directory, mode: mode}} -> {:error, {:insecure_root, mode}}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, root}}
      {:ok, %File.Stat{}} -> {:error, {:not_a_directory, root}}
      {:error, :enoent} -> with(:ok <- File.mkdir_p(root), do: File.chmod(root, 0o700))
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_existing_queue(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0 || {:error, {:insecure_queue, mode}} do
      case :file.open(path, [:read, :append, :binary, :raw]) do
        {:ok, fd} ->
          case seal_torn_tail(fd, path) do
            :ok ->
              {:ok, fd}

            {:error, reason} ->
              :ok = :file.close(fd)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      {:ok, _stat} -> {:error, {:not_a_file, path}}
    end
  end

  defp seal_torn_tail(fd, path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} ->
        :ok

      {:ok, %File.Stat{size: size}} ->
        case :file.pread(fd, size - 1, 1) do
          {:ok, "\n"} -> :ok
          {:ok, _byte} -> with(:ok <- :file.write(fd, "\n"), do: :file.datasync(fd))
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_root(opts) do
    case Keyword.get(opts, :transcript_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _otherwise -> {:error, :invalid_transcript_root}
    end
  end

  defp fetch_credentials(opts) do
    case Keyword.get(opts, :credentials) do
      {credentials, provider} when is_atom(credentials) and is_atom(provider) -> {:ok, {credentials, provider}}
      _otherwise -> {:error, :invalid_credentials}
    end
  end

  defp queue_path(root) when is_binary(root) and root != "", do: {:ok, Path.join(Path.expand(root), @queue_file)}
  defp queue_path(_root), do: {:error, :invalid_transcript_root}
  defp valid_id(id, _field) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp valid_id(_id, field), do: {:error, {:invalid, field}}
  defp schedule_after(delay), do: Process.send_after(self(), :run_provider_cleanup, delay)

  defp telemetry(event, measurements),
    do: :telemetry.execute([:voice_converse, :provider_cleanup, event], measurements, %{})

  defp iso8601(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso8601(time) when is_binary(time), do: time
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp split_lines(content),
    do: content |> String.split("\n") |> then(fn lines -> {Enum.drop(lines, -1), List.last(lines)} end)
end
