defmodule Aiur.GitHub.ResourceStore.Persistence do
  @moduledoc """
  ## Failing open

  Every fault — no state directory, unwritable file, corrupt document, dead
  process — degrades to the pre-store behavior: `etag/1` answers `nil` (so the
  read is unconditional, exactly as before), `processed?/1` answers `false` (so
  the event is published, exactly as before). A cache that cannot answer must
  cost throughput, never correctness, and the safe direction is a duplicate the
  publisher's own dedup window still catches — never a dropped event.

  """

  require Logger
  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.ResourceStore.{Checkpoint, Types}
  alias Aiur.JsonStore
  import Aiur.GitHub.ResourceStore.Body, only: [json_round_trips?: 1]
  import Aiur.GitHub.ResourceStore.Retention, only: [entry_expired?: 2, body_expired?: 2, drop_body: 1]
  import Aiur.GitHub.ResourceStore.Storage, only: [now_ms: 0]
  @retention_ms Aiur.GitHub.ResourceStore.Retention.retention_ms()
  @resource_types Types.resource_types()

  # Writes land in ETS directly from the poll fan-out rather than through this
  # process, so each mutation advances a shared revision. Periodic checkpoints
  # skip rendering when that revision is already persisted; forced flush and
  # shutdown checkpoints still render. Checkpoint caches the encoded JSON by
  # key revision, so an ordinary periodic checkpoint only encodes changed
  # entries before writing the complete restart document.
  #
  # Process hibernation releases transient checkpoint and boot allocations between timers (#3997).
  # sit on its heap until the next one.
  @spec checkpoint(map(), keyword()) :: {:ok | {:error, term()}, map()}
  def checkpoint(state, opts \\ []), do: Checkpoint.run(state, &render/1, opts)

  defp render(table) do
    entries = :ets.foldl(fn entry, acc -> encode_entry(entry, table, acc) end, [], table)
    {:ok, [~s({"version":1,"entries":{), Enum.intersperse(entries, ?,), "}}"]}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_entry({key, entry}, table, acc) do
    case encode_key(key) do
      nil ->
        # Loud, because this is the one place an entry can be lost with nothing
        # else to show for it: a key the checkpoint cannot render is simply
        # absent after the next restart. Naming it here is what makes the
        # disappearance attributable instead of a mystery.
        Logger.error("GitHub.ResourceStore cannot checkpoint key #{inspect(key)}; it will not survive a restart")

        acc

      encoded ->
        case Checkpoint.cached_entry(table, key, entry, fn current ->
               [Jason.encode!(encoded), ?:, Jason.encode!(encode_fields(key, current))]
             end) do
          nil -> acc
          cached -> [cached | acc]
        end
    end
  end

  # The same invariant `deposit_etag/3` enforces at deposit time, enforced again
  # here, because this is the other place the pair can come apart: an entry can
  # be consistent in memory and still be checkpointed as a validator whose body
  # the encoder dropped. The next boot then holds a validator with nothing behind
  # it, sends `If-None-Match`, is answered `304`, and has no data — a spent
  # request that returns nothing, which is the exact failure this store exists to
  # remove. Dropping the validator instead costs one full-price read.
  #
  # Loud for the same reason a bad key is loud: unlike a refused deposit, this
  # loss happens with no caller present to see it.
  defp encode_fields(key, entry) do
    encoded_data = entry |> Map.get(:data) |> encode_data()

    etag =
      if is_nil(encoded_data) and not is_nil(Map.get(entry, :data)) do
        Logger.error(
          "GitHub.ResourceStore cannot checkpoint the body for #{inspect(key)}; " <>
            "dropping its validator too rather than persisting a validator with no body"
        )

        nil
      else
        Map.get(entry, :etag)
      end

    %{
      "etag" => etag,
      "processed_at_ms" => Map.get(entry, :processed_at_ms),
      "version" => Map.get(entry, :version),
      "source" => entry |> Map.get(:source) |> encode_atom(),
      "recorded_at_ms" => Map.get(entry, :recorded_at_ms),
      # The body is checkpointed too. Without it a restart keeps the validators
      # but loses every answer, and the first reader after a restart pays full
      # price for state the daemon already had — which is the cost this store
      # exists to remove.
      "data" => encoded_data,
      "data_version" => Map.get(entry, :data_version),
      "data_source" => entry |> Map.get(:data_source) |> encode_atom(),
      "fetched_at_ms" => Map.get(entry, :fetched_at_ms),
      "full_body_at_ms" => Map.get(entry, :full_body_at_ms)
    }
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(_value), do: nil

  # Only a body JSON hands back unchanged is checkpointed. `storable_data/2`
  # already refused anything else at deposit time, so this is the second gate on
  # the same invariant rather than a different rule — and it is the gate that
  # catches a body written into the table by some future path that skipped the
  # deposit checks.
  defp encode_data(data) do
    if json_round_trips?(data), do: data, else: nil
  end

  defp decode_data(data) do
    if json_round_trips?(data), do: data, else: nil
  end

  # `|` cannot appear in a repo owner, name, or GitHub node id, so it is a safe
  # separator for a flat JSON object key.
  #
  # An unlisted type is refused here as well as in `key/4`, because a key built
  # by hand bypasses `key/4` entirely and `decode_key/1` would drop it on the way
  # back in. Refusing makes `encode_entry/2` say so out loud.
  defp encode_key({type, owner, repo, id}) when is_atom(type) and is_binary(owner) and is_binary(repo) and is_binary(id) do
    cond do
      type not in @resource_types -> nil
      String.contains?(owner <> repo <> id, "|") -> nil
      true -> "#{type}|#{owner}|#{repo}|#{id}"
    end
  end

  defp encode_key(_key), do: nil

  @spec load(String.t() | nil) :: [{tuple(), map()}]
  def load(nil), do: []

  def load(path) do
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
           {key, reloaded} <- reload_entry(key, entry, cutoff) do
        [{key, reloaded} | acc]
      else
        _other -> acc
      end
    end)
  end

  # The same two-tier decision as the sweep, applied at boot: an entry whose
  # recorded_at is itself past cutoff is not resurrected at all; a body past
  # retention inside an entry still in use reloads *without* its body — the mark
  # and the validator survive a restart, which is exactly when the durable
  # processed mark is the only defence against a duplicate dispatch. Answers
  # `{key, entry}` to reload, or `:skip` when nothing survives.
  defp reload_entry(key, entry, cutoff) do
    cond do
      entry_expired?(entry, cutoff) -> :skip
      body_expired?(entry, cutoff) -> {key, drop_body(entry)}
      true -> {key, entry}
    end
  end

  defp decode_key(encoded) when is_binary(encoded) do
    case String.split(encoded, "|") do
      [type, owner, repo, id] when type != "" and owner != "" and repo != "" and id != "" ->
        # Resolved against `@resource_types` alone, never against the wider set
        # `safe_atom/1` admits for the `:source` field: a checkpoint naming
        # `webhook` in the type slot would otherwise decode into a key no
        # `key/4` can build, which `encode_key/1` then refuses on the way back
        # out — an entry that exists only until the next checkpoint and cannot be
        # reached by any reader.
        case resource_type_atom(type) do
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
    resource_type_atom(value) || known_source_atom(value)
  end

  defp resource_type_atom(value), do: Enum.find(@resource_types, &(Atom.to_string(&1) == value))

  defp known_source_atom("webhook"), do: :webhook
  defp known_source_atom("poll"), do: :poll
  defp known_source_atom("mutation"), do: :mutation
  defp known_source_atom("fetch"), do: :fetch
  defp known_source_atom(_value), do: nil

  defp decode_entry(%{} = value) do
    %{
      etag: string_or_nil(Map.get(value, "etag")),
      processed_at_ms: integer_or_nil(Map.get(value, "processed_at_ms")),
      version: string_or_nil(Map.get(value, "version")),
      source: value |> Map.get("source") |> decode_source(),
      recorded_at_ms: integer_or_nil(Map.get(value, "recorded_at_ms")) || 0,
      data: decode_data(Map.get(value, "data")),
      data_version: string_or_nil(Map.get(value, "data_version")),
      data_source: value |> Map.get("data_source") |> decode_source(),
      fetched_at_ms: integer_or_nil(Map.get(value, "fetched_at_ms")),
      full_body_at_ms: integer_or_nil(Map.get(value, "full_body_at_ms"))
    }
  end

  defp decode_entry(_value), do: nil

  defp decode_source(value) when is_binary(value), do: safe_atom(value)
  defp decode_source(_value), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  @spec resolve_path(keyword()) :: String.t() | nil
  def resolve_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, nil} ->
        nil

      {:ok, path} when is_binary(path) ->
        path

      :error ->
        Settings.current().resource_store_path
    end
  end
end
