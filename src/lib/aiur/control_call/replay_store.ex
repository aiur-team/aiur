defmodule Aiur.ControlCall.ReplayStore do
  @moduledoc """
  At-most-once ledger for remote control writes keyed by `{token, request_id}`.

  `claim/3` records a durable `begin` before the call runs; `finish/5` records
  the exact response. A `begin` with no `end` found at boot means the daemon
  died mid-call, so it becomes a stored 409 `outcome_unknown`: the call is never
  re-run. Responses are stored as status plus JSON body, so a replay is
  byte-equal. State is an ETS mirror of an fsync'd journal under
  `Paths.control_replay_state_dir/0`; entries live 24 hours.

  Limits, overridable in tests through `config :aiur, :control_replay`:
  `ttl_ms`, `max_entries` (oldest completed entry evicted, in-flight never),
  `max_body_bytes` (a larger response is stored as 409 `result_not_retained`),
  `max_file_bytes` (an over-cap or corrupt file is rotated to `*.bad`, never
  deleted) and `now_fun`.
  """

  use GenServer

  alias Aiur.Config.Paths
  alias Aiur.Journal

  require Logger

  @defaults [ttl_ms: 86_400_000, max_entries: 10_000, max_body_bytes: 65_536, max_file_bytes: 16_777_216, now_fun: &System.system_time/1]
  @compact_every_ms 3_600_000
  @filename "replay.ndjson"

  @type claim_result ::
          :new
          | {:replay, pos_integer(), map(), binary()}
          | :in_progress
          | :reused
          | {:error, :unavailable | :full}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Claims `{token, request_id}` for a body hash; `:new` means the caller must run the call and `finish/6` it."
  @spec claim(binary(), binary(), binary(), GenServer.server()) :: claim_result()
  def claim(token, request_id, hash, server \\ __MODULE__), do: GenServer.call(server, {:claim, {token, request_id}, hash})

  @spec finish(binary(), binary(), pos_integer(), map(), binary(), GenServer.server()) :: :ok | {:error, term()}
  def finish(token, request_id, status, body, outcome, server \\ __MODULE__),
    do: GenServer.call(server, {:finish, {token, request_id}, status, body, outcome})

  @doc "Expires old entries and rewrites the journal."
  @spec compact(GenServer.server()) :: :ok | {:error, term()}
  def compact(server \\ __MODULE__), do: GenServer.call(server, :compact)

  @doc "Reloads from the currently configured state dir; this is also the restart path in tests."
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :compact, @compact_every_ms)
    {:ok, load(%{table: :ets.new(__MODULE__, [:set, :private]), path: nil})}
  end

  @impl GenServer
  def handle_call(:reload, _from, state), do: {:reply, :ok, load(state)}
  def handle_call(_request, _from, %{path: nil} = state), do: {:reply, {:error, :unavailable}, state}
  def handle_call(:compact, _from, state), do: {:reply, rewrite(state), state}
  def handle_call({:claim, key, hash}, _from, state), do: {:reply, do_claim(state, key, hash), state}

  def handle_call({:finish, key, status, body, outcome}, _from, state),
    do: {:reply, do_finish(state, key, status, body, outcome), state}

  @impl GenServer
  def handle_info(:compact, state) do
    if state.path, do: rewrite(state)
    Process.send_after(self(), :compact, @compact_every_ms)
    {:noreply, state}
  end

  defp do_claim(state, key, hash) do
    now = now()

    case :ets.lookup(state.table, key) do
      [{_, entry}] -> if now - entry.started < opt(:ttl_ms), do: existing(entry, hash), else: claim_new(state, key, hash, now)
      [] -> claim_new(state, key, hash, now)
    end
  end

  defp existing(%{hash: other}, hash) when other != hash, do: :reused
  defp existing(%{done: nil}, _hash), do: :in_progress
  defp existing(%{done: {status, body, outcome}}, _hash), do: {:replay, status, body, outcome}

  defp claim_new(state, {token, id} = key, hash, now) do
    with :ok <- make_room(state),
         :ok <- Journal.append(state.path, %{"t" => "begin", "token" => token, "id" => id, "hash" => hash, "at" => now}) do
      :ets.insert(state.table, {key, %{hash: hash, started: now, done: nil}})
      :new
    else
      {:error, :full} -> {:error, :full}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # An expired entry for this key is overwritten by insert; in-flight entries are never evicted.
  defp make_room(state) do
    if :ets.info(state.table, :size) < opt(:max_entries) do
      :ok
    else
      evict_oldest_done(state)
    end
  end

  defp evict_oldest_done(state) do
    done = for {key, %{done: d} = e} <- :ets.tab2list(state.table), d != nil, do: {e.started, key}

    case Enum.min(done, fn -> nil end) do
      {_, key} -> :ets.delete(state.table, key) && :ok
      nil -> {:error, :full}
    end
  end

  defp do_finish(state, {token, id} = key, status, body, outcome) do
    {status, body, outcome} = bound(Jason.decode!(Jason.encode!(body)), status, outcome)

    case :ets.lookup(state.table, key) do
      [{_, entry}] ->
        :ets.insert(state.table, {key, %{entry | done: {status, body, outcome}}})
        Journal.append(state.path, end_record(token, id, {status, body, outcome}))

      [] ->
        {:error, :unknown_request}
    end
  end

  defp bound(body, status, outcome) do
    if byte_size(Jason.encode!(body)) > opt(:max_body_bytes),
      do: {409, error_body("result_not_retained"), "result_too_large"},
      else: {status, body, outcome}
  end

  defp error_body(code), do: %{"error" => %{"code" => code}}

  defp end_record(token, id, {status, body, outcome}),
    do: %{"t" => "end", "token" => token, "id" => id, "status" => status, "body" => body, "outcome" => outcome}

  defp load(state) do
    :ets.delete_all_objects(state.table)

    case Paths.control_replay_state_dir() do
      {:ok, dir} ->
        path = Path.join(dir, @filename)
        state = %{state | path: path}

        with :ok <- Journal.prepare(dir, path),
             {:ok, records} <- replay(path),
             :ok <- restore(state, records) do
          state
        else
          reason -> quarantine(state, dir, path, reason)
        end

      {:error, _} ->
        %{state | path: nil}
    end
  end

  defp replay(path) do
    case Journal.replay(path, &{:ok, &1}, max_file_bytes: opt(:max_file_bytes), max_record_bytes: opt(:max_body_bytes) + 16_384) do
      {:ok, records, nil} -> {:ok, records}
      {:ok, _records, corruption} -> corruption
      {:error, _} = error -> error
    end
  end

  defp restore(state, records) do
    Enum.each(records, fn
      %{"t" => "begin", "token" => t, "id" => id, "hash" => h, "at" => at} ->
        :ets.insert(state.table, {{t, id}, %{hash: h, started: at, done: nil}})

      %{"t" => "end", "token" => t, "id" => id, "status" => s, "body" => b, "outcome" => o} ->
        for {key, e} <- :ets.lookup(state.table, {t, id}), do: :ets.insert(state.table, {key, %{e | done: {s, b, o}}})

      _ ->
        :ok
    end)

    # A begin with no end means the daemon died mid-call; the call may have run, so it is never re-run.
    for {key, %{done: nil} = e} <- :ets.tab2list(state.table) do
      :ets.insert(state.table, {key, %{e | done: {409, error_body("outcome_unknown"), "outcome_unknown"}}})
    end

    rewrite(state)
  end

  defp quarantine(state, dir, path, reason) do
    Logger.error("control replay store unreadable (#{inspect(reason)}); rotated to .bad and started empty, remote retry history lost")
    :ets.delete_all_objects(state.table)
    _ = File.rename(path, "#{path}.#{now()}.bad")

    case Journal.prepare(dir, path) do
      :ok -> state
      _ -> %{state | path: nil}
    end
  end

  defp rewrite(state) do
    now = now()

    {live, expired} = state.table |> :ets.tab2list() |> Enum.split_with(fn {_, e} -> now - e.started < opt(:ttl_ms) end)
    Enum.each(expired, fn {key, _} -> :ets.delete(state.table, key) end)

    lines =
      Enum.flat_map(live, fn {{t, id}, e} ->
        begin = %{"t" => "begin", "token" => t, "id" => id, "hash" => e.hash, "at" => e.started}
        if e.done, do: [begin, end_record(t, id, e.done)], else: [begin]
      end)

    Journal.rewrite(state.path, Enum.map(lines, &(Jason.encode!(&1) <> "\n")))
  end

  defp opt(key), do: :aiur |> Application.get_env(:control_replay, []) |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  defp now, do: opt(:now_fun).(:millisecond)
end
