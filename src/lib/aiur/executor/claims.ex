defmodule Aiur.Executor.Claims do
  @moduledoc """
  Leased ownership of the Executor wake stream, plus the liveness evidence a
  roster needs.

  Draining the wake inbox is destructive: acknowledging advances a shared
  cursor, so two consumers that both acknowledge silently split the stream and
  neither can tell. Ownership makes that explicit.

    * **Exactly one owner** at a time. Only the owner's acknowledgement advances
      the shared cursor.
    * The claim is a **lease with a TTL**, renewed on every consumer touch, so an
      owner that dies expires without any operator action and a successor can
      take over. Takeover resumes from the durable cursor, so the successor
      receives every record the dead owner never acknowledged.
    * A **non-owner may read** the stream. It is recorded as an observer, and its
      reads never advance the cursor.
    * Taking the stream from a **live, renewing** owner is refused and names the
      current owner. Revoking one is an explicit operator action (`revoke/2`),
      never an implicit steal.

  Nothing here inspects the environment to decide whether a caller "is an
  agent". Consumption is an explicit claim that auto-claims when nobody holds
  it, which is both simpler and correct in the cases a heuristic gets wrong.

  ## Concurrency

  The store is one JSON file at a per-repository path, so two Aiur daemons on
  one host working the same repository share it. A plain read-modify-write would
  let one daemon's stale read erase the other's fresh claim — and the loser
  would then stop acknowledging while still reporting itself healthy, which is
  precisely the undiagnosable split this module exists to prevent. Every
  mutation therefore runs under an `O_EXCL` lockfile beside the store, with a
  bounded wait and a stale-lock break, so read and write form one critical
  section across processes as well as inside one VM.

  Lease arithmetic is wall-clock: a file-shared lease has no other common time
  base. A backward clock step extends live leases and a forward step expires
  them early; both resolve on the next renew, and neither can produce two live
  owners, because the takeover check itself runs under the lock.
  """

  use GenServer

  require Logger

  alias Aiur.Executor.StatePaths
  alias Aiur.JsonStore

  # Longer than the default `executor-wait` timeout so a healthy owner blocked
  # in a quiet wait never expires mid-wait. The CLI renews while it waits, but
  # the TTL must not depend on that for correctness.
  @default_lease_ttl_ms 600_000
  # Expired entries stay visible long enough for a roster to explain a takeover,
  # then stop accumulating.
  @retention_ms 86_400_000
  @lock_timeout_ms 5_000
  @lock_retry_ms 25
  # A lockfile older than this belongs to a process that died holding it.
  @lock_stale_after_seconds 60

  @type entry :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claims ownership of the wake stream for `id`, or refuses when a different,
  live owner holds it.

  Returns `{:ok, entry}` on a fresh claim, a renewal, or a takeover from an
  expired owner. Returns `{:error, {:held_by, owner}}` when a live owner other
  than `id` is renewing; the caller may then read as an observer or ask the
  operator to `revoke/2`.
  """
  @spec claim(String.t(), keyword()) :: {:ok, entry()} | {:error, {:held_by, entry()} | term()}
  def claim(id, opts \\ []) when is_binary(id), do: call({:claim, id, opts})

  @doc "Registers `id` as a read-only observer and refreshes its lease."
  @spec observe(String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def observe(id, opts \\ []) when is_binary(id), do: call({:observe, id, opts})

  @doc "Renews an existing lease without changing its role."
  @spec renew(String.t(), keyword()) :: {:ok, entry()} | {:error, :unknown_consumer | term()}
  def renew(id, opts \\ []) when is_binary(id), do: call({:renew, id, opts})

  @doc "Releases `id`'s claim so the stream is immediately free."
  @spec release(String.t(), keyword()) :: :ok | {:error, term()}
  def release(id, opts \\ []) when is_binary(id), do: call({:release, id, opts})

  @doc """
  Explicit operator revoke of the current owner's claim.

  `id` must name the owner being revoked, so a caller cannot revoke "whoever
  happens to hold it" without having read the roster first.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, entry()} | {:error, :not_owner | :no_owner | term()}
  def revoke(id, opts \\ []) when is_binary(id), do: call({:revoke, id, opts})

  @doc """
  Records that `id` acknowledged records up to `cursor`.

  Refuses unless `id` is still the live owner. The caller checked ownership
  before draining; this is the point at which that check must still hold, and it
  is made inside the same locked section that writes the evidence.
  """
  @spec record_acknowledgement(String.t(), non_neg_integer(), keyword()) ::
          {:ok, entry()} | {:error, {:not_owner, entry() | nil} | term()}
  def record_acknowledgement(id, cursor, opts \\ []) when is_binary(id) and is_integer(cursor),
    do: call({:record_acknowledgement, id, cursor, opts})

  @doc "Stores one roster observation for every consumer, in a single write."
  @spec record_observations(map(), keyword()) :: :ok | {:error, term()}
  def record_observations(observation, opts \\ []) when is_map(observation),
    do: call({:record_observations, observation, opts})

  @doc "The live owner, if one holds the lease right now."
  @spec owner(keyword()) :: {:ok, entry()} | :none
  def owner(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    opts
    |> entries()
    |> Enum.find(&(&1["role"] == "owner" and live?(&1, now)))
    |> case do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  @doc "Every recorded consumer, most recently renewed first."
  @spec entries(keyword()) :: [entry()]
  def entries(opts \\ []), do: call({:entries, opts})

  @doc "The configured lease TTL in milliseconds."
  @spec lease_ttl_ms() :: pos_integer()
  def lease_ttl_ms, do: Application.get_env(:aiur, :executor_lease_ttl_ms, @default_lease_ttl_ms)

  @doc """
  Resolves the consumer identity for a CLI invocation.

  This is identity resolution, not agent detection: an explicit `--as` wins, an
  operator-set `AIUR_EXECUTOR_ID` comes next, and the fallback is a stable
  host-and-instance identifier. Nothing here branches on TTY, parent process, or
  any other guess about who is calling.
  """
  @spec resolve_consumer_id(keyword()) :: String.t()
  def resolve_consumer_id(opts \\ []) do
    explicit = Keyword.get(opts, :as)

    cond do
      is_binary(explicit) and explicit != "" -> sanitize(explicit)
      is_binary(env_id()) and env_id() != "" -> sanitize(env_id())
      true -> sanitize("#{hostname()}-#{instance_suffix()}")
    end
  end

  @doc false
  @spec live?(entry(), DateTime.t()) :: boolean()
  def live?(%{"lease_expires_at" => expires}, now) when is_binary(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, at, _offset} -> DateTime.compare(at, now) == :gt
      _invalid -> false
    end
  end

  def live?(_entry, _now), do: false

  ## ---- GenServer ----

  @impl true
  def init(opts) do
    StatePaths.ensure()
    {:ok, %{path: Keyword.get(opts, :path)}}
  end

  @impl true
  def handle_call({:entries, opts}, _from, state) do
    entries =
      state
      |> path(opts)
      |> read_at(opts)
      |> Map.values()
      |> Enum.sort_by(&renewed_at/1, {:desc, DateTime})

    {:reply, entries, state}
  end

  def handle_call({:claim, id, opts}, _from, state) do
    {:reply, mutate(state, opts, &do_claim(&1, id, opts)), state}
  end

  def handle_call({:observe, id, opts}, _from, state) do
    {:reply, mutate(state, opts, &{:ok, touch(&1, id, "observer", now(opts), opts)}), state}
  end

  def handle_call({:renew, id, opts}, _from, state) do
    {:reply, mutate(state, opts, &do_renew(&1, id, opts)), state}
  end

  def handle_call({:release, id, opts}, _from, state) do
    {:reply, unwrap_ok(mutate(state, opts, &{:replace, Map.delete(&1, id)})), state}
  end

  def handle_call({:revoke, id, opts}, _from, state) do
    {:reply, mutate(state, opts, &do_revoke(&1, id, opts)), state}
  end

  def handle_call({:record_acknowledgement, id, cursor, opts}, _from, state) do
    {:reply, mutate(state, opts, &do_record_acknowledgement(&1, id, cursor, opts)), state}
  end

  def handle_call({:record_observations, observation, opts}, _from, state) do
    {:reply, unwrap_ok(mutate(state, opts, &put_observation(&1, observation))), state}
  end

  ## ---- mutations, all executed under the store lock ----

  defp do_claim(consumers, id, opts) do
    now = now(opts)

    case Enum.find(Map.values(consumers), &(&1["role"] == "owner" and live?(&1, now) and &1["id"] != id)) do
      nil -> {:ok, touch(consumers, id, "owner", now, opts)}
      holder -> {:error, {:held_by, holder}}
    end
  end

  defp do_renew(consumers, id, opts) do
    case Map.fetch(consumers, id) do
      {:ok, existing} -> {:ok, touch(consumers, id, existing["role"], now(opts), opts)}
      :error -> {:error, :unknown_consumer}
    end
  end

  defp do_revoke(consumers, id, opts) do
    now = now(opts)
    owner = Enum.find(Map.values(consumers), &(&1["role"] == "owner" and live?(&1, now)))

    cond do
      is_nil(owner) -> {:error, :no_owner}
      owner["id"] != id -> {:error, :not_owner}
      true -> {:ok, Map.merge(owner, %{"role" => "revoked", "lease_expires_at" => iso(now), "revoked_at" => iso(now)})}
    end
  end

  # The ownership check lives here, inside the locked section, rather than in the
  # caller. Checking before the drain and advancing after it left a window in
  # which a revoke or an expiry could land between the two.
  defp do_record_acknowledgement(consumers, id, cursor, opts) do
    now = now(opts)

    case Enum.find(Map.values(consumers), &(&1["role"] == "owner" and live?(&1, now))) do
      %{"id" => ^id} = existing -> {:ok, acknowledged(existing, cursor, now)}
      other -> {:error, {:not_owner, other}}
    end
  end

  defp acknowledged(existing, cursor, now) do
    Map.merge(existing, %{
      "last_acknowledged_at" => iso(now),
      "acknowledged_count" => (existing["acknowledged_count"] || 0) + 1,
      "cursor_at_last_ack" => cursor,
      "last_renewed_at" => iso(now),
      "lease_expires_at" => iso(DateTime.add(now, lease_ttl_ms(), :millisecond))
    })
  end

  defp put_observation(consumers, observation) do
    {:replace, Map.new(consumers, fn {id, entry} -> {id, Map.put(entry, "observation", observation)} end)}
  end

  defp touch(consumers, id, role, now, opts) do
    existing = Map.get(consumers, id, %{})

    %{
      "id" => id,
      "role" => role || "observer",
      "host" => Keyword.get(opts, :host) || existing["host"] || hostname(),
      "pid" => Keyword.get(opts, :pid) || existing["pid"] || os_pid(),
      "claimed_at" => claimed_at(existing, role, now),
      "last_renewed_at" => iso(now),
      "lease_expires_at" => iso(DateTime.add(now, lease_ttl_ms(), :millisecond)),
      "last_acknowledged_at" => existing["last_acknowledged_at"],
      "acknowledged_count" => existing["acknowledged_count"] || 0,
      "cursor_at_last_ack" => existing["cursor_at_last_ack"],
      "observation" => existing["observation"]
    }
  end

  defp claimed_at(existing, role, now) do
    if existing["role"] == role and is_binary(existing["claimed_at"]), do: existing["claimed_at"], else: iso(now)
  end

  ## ---- store access ----

  defp call(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, message, 30_000)
      _no_server -> handle_without_server(message)
    end
  end

  # The claims store is a file, so a CLI path that runs before (or without) the
  # supervised server still resolves correctly, and correctness across daemons
  # rests on the lockfile rather than on this GenServer.
  defp handle_without_server(message) do
    {:reply, reply, _state} = handle_call(message, nil, %{path: nil})
    reply
  end

  # Read and write are one critical section. `update` returns `{:ok, entry}` to
  # replace one entry, `{:replace, consumers}` to replace the whole map, or
  # `{:error, reason}` to abort without writing.
  defp mutate(state, opts, update) do
    path = path(state, opts)

    with_lock(path, fn ->
      consumers = read_at(path, opts)

      case update.(consumers) do
        {:ok, %{"id" => id} = entry} -> write(path, opts, Map.put(consumers, id, entry), {:ok, entry})
        {:replace, updated} -> write(path, opts, updated, {:ok, :ok})
        {:error, _reason} = error -> error
      end
    end)
  end

  defp unwrap_ok({:ok, :ok}), do: :ok
  defp unwrap_ok(other), do: other

  defp with_lock(path, fun), do: acquire_lock(path, fun, @lock_timeout_ms)

  defp acquire_lock(path, fun, remaining_ms) do
    lock = path <> ".lock"

    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        hold_lock(device, lock, fun)

      {:error, :eexist} ->
        retry_lock(path, fun, lock, remaining_ms)

      {:error, reason} ->
        # A store whose directory is unwritable cannot be arbitrated at all.
        # Fail loudly rather than proceeding unlocked and losing a peer's claim.
        {:error, {:executor_claims_lock_unavailable, lock, reason}}
    end
  end

  # `after` has no implicit-function form, so the explicit resource boundary is
  # required to release this cross-process lease on every exit path.
  defp hold_lock(device, lock, fun) do
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      fun.()
    after
      File.close(device)
      File.rm(lock)
    end
  end

  defp retry_lock(path, fun, lock, remaining_ms) when remaining_ms > 0 do
    break_stale_lock(lock)
    Process.sleep(@lock_retry_ms)
    acquire_lock(path, fun, remaining_ms - @lock_retry_ms)
  end

  defp retry_lock(_path, _fun, lock, _remaining_ms), do: {:error, {:executor_claims_lock_timeout, lock}}

  # A holder that died leaves the file behind forever. Break it only once it is
  # older than any legitimate critical section could last.
  defp break_stale_lock(lock) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(lock, time: :posix),
         true <- System.os_time(:second) - mtime > @lock_stale_after_seconds do
      Logger.warning("aiur_executor_claims phase=stale_lock_broken path=#{lock}")
      _ = File.rm(lock)
    end

    :ok
  end

  defp read_at(path, opts) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"consumers" => %{} = consumers}} -> consumers |> valid_consumers() |> prune(now(opts))
      _unusable -> %{}
    end
  end

  # The file is shared between daemons and is plain JSON on disk, so a truncated,
  # hand-edited, or older-format entry is a real possibility. Drop what cannot be
  # interpreted rather than letting it raise inside a roster read.
  defp valid_consumers(consumers) do
    consumers |> Enum.filter(&valid_consumer?/1) |> Map.new()
  end

  defp valid_consumer?({id, %{"id" => id, "role" => role, "lease_expires_at" => expires, "last_renewed_at" => renewed}})
       when is_binary(id) and is_binary(role) and is_binary(expires) and is_binary(renewed),
       do: true

  defp valid_consumer?(_entry), do: false

  defp write(path, opts, consumers, reply) do
    JsonStore.write!(path, %{"consumers" => prune(consumers, now(opts))})
    reply
  rescue
    error -> {:error, {:executor_claims_unavailable, Exception.message(error)}}
  end

  defp prune(consumers, now) do
    floor = DateTime.add(now, -@retention_ms, :millisecond)

    consumers
    |> Enum.filter(fn {_id, entry} -> DateTime.compare(renewed_at(entry), floor) == :gt end)
    |> Map.new()
  end

  defp renewed_at(%{"last_renewed_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, renewed, _offset} -> renewed
      _invalid -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp renewed_at(_entry), do: ~U[1970-01-01 00:00:00Z]

  defp path(state, opts), do: Keyword.get(opts, :path) || state[:path] || StatePaths.claims_path()

  defp now(opts), do: Keyword.get(opts, :now) || DateTime.utc_now()
  defp iso(datetime), do: DateTime.to_iso8601(datetime)

  defp env_id, do: System.get_env("AIUR_EXECUTOR_ID")

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  defp os_pid, do: System.pid()

  defp instance_suffix do
    case System.get_env("AIUR_INSTANCE_KEY") do
      key when is_binary(key) and key != "" -> String.slice(key, 0, 12)
      _unset -> "default"
    end
  end

  defp sanitize(value), do: String.replace(value, ~r/[^A-Za-z0-9._-]/, "_")
end
