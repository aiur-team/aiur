defmodule Aiur.Executor.Claims do
  @moduledoc """
  Leased ownership of the Executor wake stream, plus the liveness evidence a
  roster needs.

  Draining the wake inbox is destructive: `acknowledge/2` advances a shared
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
  """

  use GenServer

  alias Aiur.Executor.StatePaths
  alias Aiur.JsonStore

  @default_lease_ttl_ms 120_000
  # Expired entries stay visible long enough for a roster to explain a takeover,
  # then stop accumulating.
  @retention_ms 86_400_000

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

  @doc "Records that `id` acknowledged records up to `cursor`."
  @spec record_acknowledgement(String.t(), non_neg_integer(), keyword()) :: {:ok, entry()} | {:error, term()}
  def record_acknowledgement(id, cursor, opts \\ []) when is_binary(id) and is_integer(cursor),
    do: call({:record_acknowledgement, id, cursor, opts})

  @doc "Stores a roster observation so the next roster read can tell whether the cursor moved."
  @spec record_observation(String.t(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  def record_observation(id, observation, opts \\ []) when is_binary(id) and is_map(observation),
    do: call({:record_observation, id, observation, opts})

  @doc "The live owner, if one holds the lease right now."
  @spec owner(keyword()) :: {:ok, entry()} | :none
  def owner(opts \\ []), do: call({:owner, opts})

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
      _ -> false
    end
  end

  def live?(_entry, _now), do: false

  ## ---- GenServer ----

  @impl true
  def init(opts) do
    {:ok, %{path: Keyword.get(opts, :path)}}
  end

  @impl true
  def handle_call({:owner, opts}, _from, state) do
    now = now(opts)

    reply =
      state
      |> read(opts)
      |> Map.values()
      |> Enum.find(&(&1["role"] == "owner" and live?(&1, now)))
      |> case do
        nil -> :none
        entry -> {:ok, entry}
      end

    {:reply, reply, state}
  end

  def handle_call({:entries, opts}, _from, state) do
    entries =
      state
      |> read(opts)
      |> Map.values()
      |> Enum.sort_by(& &1["last_renewed_at"], &>=/2)

    {:reply, entries, state}
  end

  def handle_call({:claim, id, opts}, _from, state) do
    now = now(opts)
    consumers = read(state, opts)

    case Enum.find(Map.values(consumers), &(&1["role"] == "owner" and live?(&1, now) and &1["id"] != id)) do
      nil ->
        entry = touch(consumers, id, "owner", now, opts)
        {:reply, write(state, opts, Map.put(consumers, id, entry), entry), state}

      holder ->
        {:reply, {:error, {:held_by, holder}}, state}
    end
  end

  def handle_call({:observe, id, opts}, _from, state) do
    now = now(opts)
    consumers = read(state, opts)
    entry = touch(consumers, id, "observer", now, opts)
    {:reply, write(state, opts, Map.put(consumers, id, entry), entry), state}
  end

  def handle_call({:renew, id, opts}, _from, state) do
    now = now(opts)
    consumers = read(state, opts)

    case Map.fetch(consumers, id) do
      {:ok, existing} ->
        entry = touch(consumers, id, existing["role"], now, opts)
        {:reply, write(state, opts, Map.put(consumers, id, entry), entry), state}

      :error ->
        {:reply, {:error, :unknown_consumer}, state}
    end
  end

  def handle_call({:release, id, opts}, _from, state) do
    consumers = read(state, opts)
    {:reply, write(state, opts, Map.delete(consumers, id), :ok), state}
  end

  def handle_call({:revoke, id, opts}, _from, state) do
    now = now(opts)
    consumers = read(state, opts)
    owner = Enum.find(Map.values(consumers), &(&1["role"] == "owner" and live?(&1, now)))

    cond do
      is_nil(owner) ->
        {:reply, {:error, :no_owner}, state}

      owner["id"] != id ->
        {:reply, {:error, :not_owner}, state}

      true ->
        revoked = owner |> Map.put("role", "revoked") |> Map.put("lease_expires_at", iso(now)) |> Map.put("revoked_at", iso(now))
        {:reply, write(state, opts, Map.put(consumers, id, revoked), revoked), state}
    end
  end

  def handle_call({:record_acknowledgement, id, cursor, opts}, _from, state) do
    now = now(opts)
    consumers = read(state, opts)

    case Map.fetch(consumers, id) do
      {:ok, existing} ->
        entry =
          existing
          |> Map.merge(%{
            "last_acknowledged_at" => iso(now),
            "acknowledged_count" => (existing["acknowledged_count"] || 0) + 1,
            "cursor_at_last_ack" => cursor,
            "last_renewed_at" => iso(now),
            "lease_expires_at" => iso(DateTime.add(now, lease_ttl_ms(), :millisecond))
          })

        {:reply, write(state, opts, Map.put(consumers, id, entry), entry), state}

      :error ->
        {:reply, {:error, :unknown_consumer}, state}
    end
  end

  def handle_call({:record_observation, id, observation, opts}, _from, state) do
    consumers = read(state, opts)

    case Map.fetch(consumers, id) do
      {:ok, existing} ->
        entry = Map.put(existing, "observation", observation)
        {:reply, write(state, opts, Map.put(consumers, id, entry), entry), state}

      :error ->
        {:reply, {:error, :unknown_consumer}, state}
    end
  end

  ## ---- internals ----

  defp call(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, message, 15_000)
      _ -> handle_without_server(message)
    end
  end

  # The claims store is a file, so a CLI path that runs before (or without) the
  # supervised server still resolves correctly. The server only serializes
  # concurrent writers inside one daemon.
  defp handle_without_server(message) do
    {:reply, reply, _state} = handle_call(message, nil, %{path: nil})
    reply
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

  defp read(state, opts) do
    case JsonStore.read(path(state, opts), %{}) do
      {:ok, %{"consumers" => %{} = consumers}} -> prune(consumers, now(opts))
      _ -> %{}
    end
  end

  defp write(state, opts, consumers, reply) do
    JsonStore.write!(path(state, opts), %{"consumers" => prune(consumers, now(opts))})

    case reply do
      :ok -> :ok
      entry -> {:ok, entry}
    end
  rescue
    error -> {:error, {:executor_claims_unavailable, Exception.message(error)}}
  end

  defp prune(consumers, now) do
    floor = DateTime.add(now, -@retention_ms, :millisecond)

    consumers
    |> Enum.filter(fn {_id, entry} -> retain?(entry, floor) end)
    |> Map.new()
  end

  defp retain?(%{"last_renewed_at" => at}, floor) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, renewed, _offset} -> DateTime.compare(renewed, floor) == :gt
      _ -> false
    end
  end

  defp retain?(_entry, _floor), do: false

  defp path(state, opts) do
    Keyword.get(opts, :path) || state[:path] || StatePaths.claims_path()
  end

  defp now(opts), do: Keyword.get(opts, :now) || DateTime.utc_now()
  defp iso(datetime), do: DateTime.to_iso8601(datetime)

  defp env_id, do: System.get_env("AIUR_EXECUTOR_ID")

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "unknown-host"
    end
  end

  defp os_pid, do: System.pid()

  defp instance_suffix do
    case System.get_env("AIUR_INSTANCE_KEY") do
      key when is_binary(key) and key != "" -> String.slice(key, 0, 12)
      _ -> "default"
    end
  end

  defp sanitize(value), do: String.replace(value, ~r/[^A-Za-z0-9._-]/, "_")
end
