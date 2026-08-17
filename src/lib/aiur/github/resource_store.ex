defmodule Aiur.GitHub.ResourceStore do
  @moduledoc """
  Restart-durable GitHub state keyed by **resource identity**, not by call site.

  Aiur learns the same GitHub fact through more than one pipe. A comment arrives
  free over a webhook and is then read again, at full price, by the comment poll
  sweep. `Aiur.Events.GitHubWebhook.Normalizer` already reduces a delivery to
  keys "taken one for one from `CommentPollBatch.normalize_comments/1`" so that
  consumers cannot tell the two apart — which is the proof that they are the
  same event, and therefore that one of the two reads is waste.

  This store is where the pipes meet. Every entry is addressed by
  `{resource_type, owner, repo, id}`, so a comment written by the webhook pipe
  and the same comment seen by the poll sweep resolve to one entry regardless of
  which API shape produced it. Keying by call site instead would make the entry
  unreadable from the other pipe, which is the whole point.

  ## What an entry holds

    * `:etag` — the validator for a conditional re-read. A `304` costs nothing
      against GitHub's primary REST limit, so a sweep over unchanged resources
      is free rather than merely cheap.
    * `:processed_at_ms` — the moment some pipe finished processing this exact
      resource. This is the suppress half of the sweep.
    * `:version` — the resource's own mutation marker, a comment's `updated_at`.

  ## Identity says *which* resource; version says *which state of it*

  A GitHub comment is mutable. An edit keeps the id and moves only `updated_at`,
  and the sweep's `?since=` filter is on `updated_at`, so an edited comment comes
  back around on the next cycle. Suppressing on identity alone would read that as
  a redelivery of the original and swallow it for the full retention window —
  three days, across restarts. Editing a comment to correct an agent's
  instructions is a normal workflow here, so that would be a real loss.

  So a mark records the version it was made at, and a resource whose version has
  moved reads as unprocessed. Note this is *not* a watermark: nothing is compared
  for order, only for equality against the version that was actually processed.
  An older lost comment still recovers, because it is a different resource
  entirely.

  Shortening the retention window would have bought the edit back by giving up
  the thing the window exists for — a delivery GitHub retries up to three days
  later — so the version is recorded instead.

  ## Suppress and recover are not in tension once the key is identity

  The sweep must not re-process what the webhook already delivered, and it must
  still recover a delivery that was lost. Measured here: 9 of 100 deliveries
  returned 502 during a daemon restart, GitHub retried none, and none arrived
  later. Those two requirements only fight each other if suppression is decided
  by a *timestamp watermark* — "ignore anything older than the newest thing I
  saw" also ignores an older sibling whose delivery was dropped.

  Deciding per resource identity removes the conflict outright. A comment the
  webhook processed is marked and is skipped by name; a comment whose delivery
  was lost was never marked, so the very next sweep publishes it. The sweep
  itself is never skipped, so there is no window in which a gap cannot be seen.

  ## Failing open

  Every fault — no state directory, unwritable file, corrupt document, dead
  process — degrades to the pre-store behavior: `etag/1` answers `nil` (so the
  read is unconditional, exactly as before), `processed?/1` answers `false` (so
  the event is published, exactly as before). A cache that cannot answer must
  cost throughput, never correctness, and the safe direction is a duplicate the
  publisher's own dedup window still catches — never a dropped event.

  ## Retention

  Entries expire after 72 hours, matching `Aiur.Webhooks.DeliveryLog`: that is
  the envelope inside which GitHub will still retry a delivery, so it is the
  window in which a duplicate can still legitimately arrive.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, Fs, JsonStore}

  @table __MODULE__.Table
  @retention_ms 72 * 60 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  @checkpoint_interval_ms 30 * 1000
  @filename "github_resources.json"
  @max_entries 100_000

  # Ceiling on a single cached response body, encoded. A Build Order graph
  # response over 54 members is large, and an unbounded body cache is a memory
  # leak wearing a cache's clothes. Anything past this is refused rather than
  # stored, and refusing also drops the validator so the pair stays consistent.
  @max_payload_bytes 256 * 1024

  # The closed set of resource identities. Declared here rather than left to
  # whichever module happens to be loaded first, because `decode_key/1` resolves
  # a checkpointed type with `String.to_existing_atom/1` and would otherwise
  # drop entries for a type whose only mention lives in a not-yet-loaded module.
  @resource_types [
    # Individual events — the identity both pipes agree on, used to decide
    # whether this exact comment/review has already been processed.
    :issue_comment,
    :pr_review_comment,
    :pr_review,
    # Endpoint reads — the identity a conditional request validator belongs to.
    :issue_comments,
    :pr_issue_comments,
    :pull_request,
    :pull_request_reviews,
    :labelled_pull_requests
  ]

  @type resource_type :: atom()
  @type key :: {resource_type(), String.t(), String.t(), String.t()}

  @doc "Every resource identity this store recognises."
  @spec resource_types() :: [resource_type()]
  def resource_types, do: @resource_types

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Builds a canonical resource key.

  `owner` and `repo` are down-cased because the two pipes disagree on casing:
  the poller uses the configured repo identity while the webhook uses GitHub's
  delivered `repository.full_name`. An exact-match store would silently miss on
  that difference and both pipes would process the same comment.
  """
  @spec key(resource_type(), String.t(), String.t(), term()) :: key() | nil
  def key(resource_type, owner, repo, id) when is_atom(resource_type) and is_binary(owner) and is_binary(repo) do
    case normalize_id(id) do
      nil -> nil
      normalized -> {resource_type, String.downcase(owner), String.downcase(repo), normalized}
    end
  end

  def key(_resource_type, _owner, _repo, _id), do: nil

  @doc """
  Builds a resource key from an `"owner/name"` string.

  Answers `nil` for anything that is not a two-segment repository identity, so a
  caller that cannot name its repo degrades to the storeless path rather than
  writing an entry the other pipe could never find.
  """
  @spec key_for_repo(resource_type(), String.t() | nil, term()) :: key() | nil
  def key_for_repo(resource_type, full_name, id) when is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" -> key(resource_type, owner, repo, id)
      _other -> nil
    end
  end

  def key_for_repo(_resource_type, _full_name, _id), do: nil

  @doc "The stored validator for `key`, or `nil` when there is none."
  @spec etag(key() | nil) :: String.t() | nil
  def etag(nil), do: nil

  def etag(key) do
    case lookup(key) do
      %{etag: etag} when is_binary(etag) and etag != "" -> etag
      _other -> nil
    end
  end

  @doc """
  Stores a validator for `key`. A `nil` or empty validator is discarded.

  A validator is only useful alongside the body it validates — see
  `put_payload/2` for why the two are written together.
  """
  @spec put_etag(key() | nil, String.t() | nil) :: :ok
  def put_etag(nil, _etag), do: :ok
  def put_etag(_key, etag) when not is_binary(etag) or etag == "", do: :ok

  def put_etag(key, etag) do
    update(key, fn entry -> Map.put(entry, :etag, etag) end)
  end

  @doc """
  The cached response body for `key`, or `nil`.

  ## Why the store must hold bodies, not just validators

  A validator alone cannot serve a second reader. If two consumers want the same
  resource and the store holds only an `ETag`, the second sends `If-None-Match`,
  receives `304 Not Modified` — and a `304` carries **no body**. It has spent a
  request and learned nothing it can use.

  That turns a duplicate fetch into a *dropped read*, which is strictly worse
  than the duplication it was meant to remove. So a reader is only served from
  the store when the body is present.
  """
  @spec payload(key() | nil) :: term() | nil
  def payload(nil), do: nil

  def payload(key) do
    case lookup(key) do
      %{payload: payload} = entry when not is_nil(payload) ->
        # Body freshness keys off when the body was *recorded*, not off
        # `processed_at_ms`. Those are different facts: a fetch can cache a body
        # for other readers without any pipe having processed that resource, and
        # keying off the processing mark would make such a body invisible.
        if expired?(Map.get(entry, :recorded_at_ms)), do: nil, else: payload

      _other ->
        nil
    end
  end

  @doc """
  Stores a response body for `key`, optionally with the validator that proves it
  current.

  Prefer this over `put_etag/2` whenever a fetch actually returned data. A
  validator on its own is still useful — the sweep sends `If-None-Match` purely
  to learn *whether anything changed*, and a `304` answers that for free without
  needing a body. But a validator alone can never **serve** a second reader, and
  that distinction is the rule callers must respect:

  > Ask `payload/1` before spending a request. Never treat a `304` as data.

  A reader that finds no body must fetch, even when a validator exists.
  `payload/1` enforces this by answering `nil` whenever the body is absent, so a
  caller cannot accidentally mistake "unchanged" for "here it is".

  Bodies are bounded: anything larger than #{div(@max_payload_bytes, 1024)} KiB
  encoded is refused rather than stored, because a cached graph response over 54
  members is large and an unbounded body cache is a memory leak wearing a
  cache's clothes. Refusing keeps any existing validator, since change detection
  is still worth having when the body is not.
  """
  @spec put_payload(key() | nil, term(), String.t() | nil) :: :ok
  def put_payload(key, payload, etag \\ nil)

  def put_payload(nil, _payload, _etag), do: :ok

  def put_payload(key, payload, etag) do
    if oversized?(payload) do
      # Refuse the body but keep change detection: drop only the stale payload.
      drop_payload(key)
    else
      update(key, fn entry ->
        entry
        |> Map.put(:payload, payload)
        |> then(fn e -> if is_binary(etag) and etag != "", do: Map.put(e, :etag, etag), else: e end)
      end)
    end
  end

  @doc """
  Removes the cached body for `key`, leaving any validator in place.

  The validator still answers "has this changed?" cheaply. It simply cannot
  answer "what is it?" — which is why `payload/1` returns `nil` here and the
  caller fetches.
  """
  @spec drop_payload(key() | nil) :: :ok
  def drop_payload(nil), do: :ok

  def drop_payload(key) do
    update(key, fn entry -> Map.delete(entry, :payload) end)
  end

  defp oversized?(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> byte_size(encoded) > @max_payload_bytes
      # Unencodable payloads cannot be persisted or measured, so treat them as
      # oversized rather than storing something the checkpoint would choke on.
      _error -> true
    end
  end

  @doc """
  True when some pipe has already processed this exact resource *at this
  version*.

  `version` is the resource's own mutation marker — a comment's `updated_at`.
  Identity alone is not enough to decide "already handled", because a GitHub
  comment is mutable: its id is stable across an edit and only `updated_at`
  moves. Editing a ticket comment to correct an agent's instructions is a normal
  workflow here and it must re-wake the agent, so a resource whose version has
  changed since it was marked reads as unprocessed and is published again.

  Answers `false` whenever the store cannot answer, because publishing a
  duplicate is recoverable and dropping an event is not.
  """
  @spec processed?(key() | nil, String.t() | nil) :: boolean()
  def processed?(key, version \\ nil)

  def processed?(nil, _version), do: false

  def processed?(key, version) do
    case lookup(key) do
      %{processed_at_ms: at} = entry when is_integer(at) ->
        not expired?(at) and Map.get(entry, :version) == normalize_version(version)

      _other ->
        false
    end
  end

  @doc """
  Marks `key` processed by `source` (`:webhook` or `:poll`) at `version`.

  Recording the version is what lets a later edit of the same resource be told
  apart from a redelivery of it.
  """
  @spec mark_processed(key() | nil, atom(), String.t() | nil) :: :ok
  def mark_processed(key, source, version \\ nil)

  def mark_processed(nil, _source, _version), do: :ok

  def mark_processed(key, source, version) when is_atom(source) do
    update(key, fn entry ->
      entry
      |> Map.put(:processed_at_ms, now_ms())
      |> Map.put(:source, source)
      |> Map.put(:version, normalize_version(version))
    end)
  end

  @doc """
  Marks `key` processed at `version` only if it was not already.

  Returns `:marked` for the first caller and `:already_processed` for every
  later one inside the retention window, so a caller can gate a publish on the
  answer without a separate read.
  """
  @spec claim(key() | nil, atom(), String.t() | nil) :: :marked | :already_processed
  def claim(key, source, version \\ nil)

  def claim(nil, _source, _version), do: :marked

  def claim(key, source, version) when is_atom(source) do
    if processed?(key, version) do
      :already_processed
    else
      mark_processed(key, source, version)
      :marked
    end
  end

  @doc """
  Drops every entry.

  Test seam. The store is deliberately global and long-lived, which in a suite
  means one case's published comment can suppress an unrelated case that reuses
  the same fixture id — the same hazard `Aiur.Events.Publisher`'s dedup table
  already has, and the shared test setup clears both for the same reason.
  """
  @spec reset() :: :ok
  def reset do
    with_table(:ok, fn table ->
      :ets.delete_all_objects(table)
      :ok
    end)
  end

  @doc false
  @spec forget(key() | nil) :: :ok
  def forget(nil), do: :ok

  def forget(key) do
    with_table(:ok, fn table ->
      :ets.delete(table, key)
      :ok
    end)
  end

  @doc false
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, 15_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Entry count, or `0` when no store is running."
  @spec size() :: non_neg_integer()
  def size do
    with_table(0, fn table -> :ets.info(table, :size) || 0 end)
  end

  # -- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    path = resolve_path(opts)
    loaded = load(path)
    Enum.each(loaded, &:ets.insert(table, &1))

    if path, do: schedule(:checkpoint, checkpoint_interval(opts))
    schedule(:sweep, sweep_interval(opts))

    {:ok, %{table: table, path: path, last_written: nil}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {reply, state} = checkpoint(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:checkpoint, state) do
    {_reply, state} = checkpoint(state)
    schedule(:checkpoint, @checkpoint_interval_ms)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep(state.table)
    schedule(:sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    checkpoint(state)
    :ok
  end

  # -- internals ------------------------------------------------------------

  defp sweep_interval(opts), do: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
  defp checkpoint_interval(opts), do: Keyword.get(opts, :checkpoint_interval_ms, @checkpoint_interval_ms)

  defp schedule(message, interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), message, interval)
  end

  defp schedule(_message, _interval), do: :ok

  defp lookup(key) do
    with_table(nil, fn table ->
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end
    end)
  end

  defp update(key, fun) do
    with_table(:ok, fn table ->
      existing =
        case :ets.lookup(table, key) do
          [{^key, entry}] -> entry
          _other -> %{}
        end

      entry = existing |> fun.() |> Map.put(:recorded_at_ms, now_ms())
      :ets.insert(table, {key, entry})
      :ok
    end)
  end

  # Every read and write funnels through here so a missing table — no store
  # started, a store that crashed, a test that never booted one — is answered
  # with the caller's storeless default instead of raising into a poll task.
  defp with_table(default, fun) do
    case :ets.whereis(@table) do
      :undefined -> default
      table -> fun.(table)
    end
  rescue
    ArgumentError -> default
  end

  defp now_ms, do: System.system_time(:millisecond)

  # Only ever reached with an integer: `processed?/1` guards on `is_integer/1`
  # before asking, so a second catch-all clause here would be unreachable.
  defp expired?(at) when is_integer(at), do: now_ms() - at > @retention_ms

  defp sweep(table) do
    cutoff = now_ms() - @retention_ms

    expired =
      :ets.foldl(
        fn {key, entry}, acc ->
          if Map.get(entry, :recorded_at_ms, 0) < cutoff, do: [key | acc], else: acc
        end,
        [],
        table
      )

    Enum.each(expired, &:ets.delete(table, &1))

    # A hard backstop far above real volume. Crossing it means the retention
    # window alone is not bounding the set, so drop the oldest rather than let
    # the daemon's memory follow GitHub traffic without limit.
    overflow = (:ets.info(table, :size) || 0) - @max_entries

    if overflow > 0 do
      Logger.warning("GitHub.ResourceStore exceeded #{@max_entries} entries; evicting #{overflow} oldest")

      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, entry} -> Map.get(entry, :recorded_at_ms, 0) end)
      |> Enum.take(overflow)
      |> Enum.each(fn {key, _entry} -> :ets.delete(table, key) end)
    end

    :ok
  end

  # Writes land in ETS directly from the poll fan-out rather than through this
  # process, so there is no dirty flag to trust: the checkpoint compares the
  # rendered document against the last one written and skips an identical one.
  # That keeps a steady-state cycle — the case this whole change exists to make
  # free — from also becoming a disk write every 30 seconds.
  defp checkpoint(%{path: nil} = state), do: {:ok, state}

  defp checkpoint(%{table: table, path: path} = state) do
    document = table |> :ets.tab2list() |> Enum.reduce(%{}, &encode_entry/2)

    if document == state.last_written do
      {:ok, state}
    else
      case write(path, document) do
        :ok ->
          {:ok, %{state | last_written: document}}

        {:error, reason} = error ->
          Logger.warning("GitHub.ResourceStore checkpoint failed; reason=#{inspect(reason)}")
          {error, state}
      end
    end
  end

  defp write(path, document) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(%{"version" => 1, "entries" => document}) do
      Fs.atomic_write(path, encoded, fsync: true, mode: 0o600)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_entry({key, entry}, acc) do
    case encode_key(key) do
      nil ->
        acc

      encoded ->
        Map.put(acc, encoded, %{
          "etag" => Map.get(entry, :etag),
          "payload" => Map.get(entry, :payload),
          "processed_at_ms" => Map.get(entry, :processed_at_ms),
          "version" => Map.get(entry, :version),
          "source" => entry |> Map.get(:source) |> encode_atom(),
          "recorded_at_ms" => Map.get(entry, :recorded_at_ms)
        })
    end
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(_value), do: nil

  # `|` cannot appear in a repo owner, name, or GitHub node id, so it is a safe
  # separator for a flat JSON object key.
  defp encode_key({type, owner, repo, id}) when is_atom(type) and is_binary(owner) and is_binary(repo) and is_binary(id) do
    if String.contains?(owner <> repo <> id, "|"), do: nil, else: "#{type}|#{owner}|#{repo}|#{id}"
  end

  defp encode_key(_key), do: nil

  defp load(nil), do: []

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"entries" => %{} = entries}} -> decode_entries(entries)
      {:ok, _other} -> []
      {:error, reason} -> log_unreadable(path, reason)
    end
  end

  # A corrupt or unreadable checkpoint costs one cold sweep, which is exactly
  # the pre-store behavior. Refusing to boot over it would be strictly worse.
  defp log_unreadable(path, reason) do
    Logger.warning("GitHub.ResourceStore checkpoint unreadable at #{path}; starting cold reason=#{inspect(reason)}")
    []
  end

  defp decode_entries(entries) do
    cutoff = now_ms() - @retention_ms

    Enum.reduce(entries, [], fn {encoded, value}, acc ->
      with key when not is_nil(key) <- decode_key(encoded),
           %{} = entry <- decode_entry(value),
           true <- Map.get(entry, :recorded_at_ms, 0) >= cutoff do
        [{key, entry} | acc]
      else
        _other -> acc
      end
    end)
  end

  defp decode_key(encoded) when is_binary(encoded) do
    case String.split(encoded, "|") do
      [type, owner, repo, id] when type != "" and owner != "" and repo != "" and id != "" ->
        case safe_atom(type) do
          nil -> nil
          atom -> {atom, owner, repo, id}
        end

      _other ->
        nil
    end
  end

  defp decode_key(_encoded), do: nil

  # A checkpoint is daemon-private, but resource types are a closed set the code
  # already defines, so an unknown one is a stale or tampered record to drop
  # rather than a new atom to create.
  defp safe_atom(value) do
    Enum.find(@resource_types, &(Atom.to_string(&1) == value)) || known_source_atom(value)
  end

  defp known_source_atom("webhook"), do: :webhook
  defp known_source_atom("poll"), do: :poll
  defp known_source_atom(_value), do: nil

  defp decode_entry(%{} = value) do
    %{
      etag: string_or_nil(Map.get(value, "etag")),
      payload: Map.get(value, "payload"),
      processed_at_ms: integer_or_nil(Map.get(value, "processed_at_ms")),
      version: string_or_nil(Map.get(value, "version")),
      source: value |> Map.get("source") |> decode_source(),
      recorded_at_ms: integer_or_nil(Map.get(value, "recorded_at_ms")) || 0
    }
  end

  defp decode_entry(_value), do: nil

  defp decode_source(value) when is_binary(value), do: safe_atom(value)
  defp decode_source(_value), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_id), do: nil

  # A resource with no readable version is stored as `nil`, which matches only
  # another `nil` — so such a resource keeps the pre-version behavior of being
  # suppressed on identity alone. That is the right default: it is the current
  # behavior, and inventing a version would make every re-read look like an
  # edit and republish the whole window every cycle.
  defp normalize_version(version) when is_binary(version) and version != "", do: version
  defp normalize_version(_version), do: nil

  defp resolve_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, nil} ->
        nil

      {:ok, path} when is_binary(path) ->
        path

      :error ->
        configured_path() || default_path()
    end
  end

  defp configured_path do
    case Application.get_env(:aiur, :github_resource_store_path) do
      path when is_binary(path) and path != "" -> path
      _other -> nil
    end
  end

  defp default_path do
    case Config.Paths.decision_state_dir() do
      {:ok, dir} ->
        Path.join(dir, @filename)

      {:error, reason} ->
        # No resolvable state directory means no durability, not no store: the
        # in-memory half still suppresses a duplicate inside one boot, which is
        # strictly better than the pre-store behavior it falls back to.
        Logger.debug("GitHub.ResourceStore has no state directory; running in-memory reason=#{inspect(reason)}")
        nil
    end
  end
end
