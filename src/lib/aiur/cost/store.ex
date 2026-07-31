defmodule Aiur.Cost.Store do
  @moduledoc """
  Per-issue GenServer that owns the durable token-usage + USD-cost total for one
  Aiur ticket.

  Persists to `<logs-root>/<repo>.<id>.cost.json` via the atomic-rename helper in
  `Aiur.JsonStore`, mirroring `Aiur.Events.SubscriptionStore`. Because the total
  is reloaded on `init/1`, it survives a BEAM restart and — crucially — a codex
  session switch: each session reports a fresh **absolute** cumulative total keyed
  by its own `thread_id`, so the per-thread high-water marks are summed across
  threads and the running per-ticket total never restarts from zero.

  ## Accounting

  Codex reports absolute cumulative token totals per thread (see
  `docs/token_accounting.md`). For each thread we keep the high-water absolute
  snapshot; the per-ticket cost tokens are the sum across threads, and USD is
  priced from those absolute totals (never per-event deltas), so re-pricing on
  every update is idempotent. The context-window figure (`tokens / limit`) tracks
  the *active* thread, i.e. the live conversation window.

  ## Lifecycle

  `record/2` lazily starts the store (idempotent) and folds one observation in,
  so no caller needs to thread attach/stop through the run lifecycle. `stop/1`
  flushes and terminates.
  """

  use GenServer

  require Logger

  alias Aiur.AgentPubSub
  alias Aiur.Config.Paths
  alias Aiur.Cost.Pricer
  alias Aiur.JsonStore

  @registry Aiur.Cost.StoreRegistry
  @supervisor Aiur.Cost.StoreSupervisor

  @allowed_providers %{"codex" => :codex, "claude" => :claude}
  @allowed_context_tiers %{
    "short_context" => :short_context,
    "long_context" => :long_context,
    "not_applicable" => :not_applicable
  }

  @empty_thread %{
    "input_tokens" => 0,
    "cached_input_tokens" => 0,
    "output_tokens" => 0,
    "total_tokens" => 0,
    "context_window" => nil
  }

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:identifier],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, opts, name: via(identifier))
  end

  @doc "Idempotently ensures a store is running for `identifier`."
  @spec attach(String.t()) :: :ok
  def attach(identifier) when is_binary(identifier) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, identifier: identifier}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Cost.Store.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Stops the store for `identifier`. No-op if not running."
  @spec stop(String.t()) :: :ok
  def stop(identifier) when is_binary(identifier) do
    case registry_lookup(identifier) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  @doc """
  Folds one absolute observation (`Aiur.Cost.Observation.t()`) into the ticket's
  running total. Starts the store on first use. Fire-and-forget: the fold runs
  asynchronously and never blocks the worker turn.
  """
  @spec record(String.t(), map()) :: :ok
  def record(identifier, %{thread_id: _} = observation) when is_binary(identifier) do
    # Fast-path the common case (store already running) with a cheap Registry
    # read, so the hot per-message path doesn't serialize a no-op start_child
    # through the DynamicSupervisor once the store exists.
    case registry_lookup(identifier) do
      [{_pid, _}] -> :ok
      [] -> attach(identifier)
    end

    GenServer.cast(via(identifier), {:record, observation})
  catch
    :exit, _reason -> :ok
  end

  def record(_identifier, _observation), do: :ok

  @doc "Current snapshot (atom-keyed) or `:not_found`."
  @spec snapshot(String.t()) :: map() | :not_found
  def snapshot(identifier) when is_binary(identifier) do
    case registry_lookup(identifier) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> :not_found
    end
  end

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)

    state = %{
      identifier: identifier,
      path: path_for(identifier),
      catalog: Pricer.catalog(),
      threads: %{},
      meta: empty_meta(),
      active_thread: nil,
      last_broadcast: nil
    }

    {:ok, load_persisted(state)}
  end

  @impl true
  def handle_cast({:record, observation}, state) do
    tid = observation.thread_id
    prev = Map.get(state.threads, tid, @empty_thread)

    merged = %{
      "input_tokens" => max(prev["input_tokens"], observation.input_tokens),
      "cached_input_tokens" => max(prev["cached_input_tokens"], observation.cached_input_tokens),
      "output_tokens" => max(prev["output_tokens"], observation.output_tokens),
      "total_tokens" => max(prev["total_tokens"], observation.total_tokens),
      "context_window" => observation.context_window || prev["context_window"]
    }

    state = %{
      state
      | threads: Map.put(state.threads, tid, merged),
        meta: merge_meta(state.meta, observation.meta),
        active_thread: tid
    }

    # Coalesce the durable write and the UI broadcast on the same bucket change.
    # Codex emits a usage update on nearly every streamed message; persisting +
    # fsyncing each one would be severe write amplification on the hot path. The
    # total is idempotent absolute high-water, so a bucket-gated flush loses at
    # most sub-bucket increments (< $1 / < 1% context), and terminate/2 always
    # flushes the latest on clean shutdown.
    snapshot = build_snapshot(state)
    key = throttle_key(snapshot)

    if key == state.last_broadcast do
      {:noreply, state}
    else
      :ok = persist(snapshot, state)
      AgentPubSub.broadcast_cost(state.identifier, snapshot)
      {:noreply, %{state | last_broadcast: key}}
    end
  rescue
    error ->
      # A malformed observation must never take the store down and drop the
      # accumulated total; log and keep the last good state.
      Logger.warning("Cost.Store(#{state.identifier}) record failed: " <> Exception.message(error))
      {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = persist(build_snapshot(state), state)
    :ok
  end

  # ── snapshot / derivation ────────────────────────────────────────────

  defp build_snapshot(state) do
    cost_tokens = sum_threads(state.threads)
    active = Map.get(state.threads, state.active_thread, @empty_thread)
    limit = active["context_window"]
    tokens = active["total_tokens"]

    %{
      context: %{tokens: tokens, limit: limit, percent_used: percent(tokens, limit)},
      cost: %{
        input_tokens: cost_tokens.input_tokens,
        output_tokens: cost_tokens.output_tokens,
        cached_input_tokens: cost_tokens.cached_input_tokens,
        usd: usd(state, cost_tokens)
      },
      provider: state.meta.provider,
      resolved_model: state.meta.resolved_model,
      last_updated_at: now_iso8601()
    }
  end

  defp sum_threads(threads) do
    Enum.reduce(threads, %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}, fn {_id, t}, acc ->
      %{
        input_tokens: acc.input_tokens + (t["input_tokens"] || 0),
        cached_input_tokens: acc.cached_input_tokens + (t["cached_input_tokens"] || 0),
        output_tokens: acc.output_tokens + (t["output_tokens"] || 0),
        total_tokens: acc.total_tokens + (t["total_tokens"] || 0)
      }
    end)
  end

  defp usd(state, cost_tokens) do
    if pricing_ready?(state.meta) do
      case Pricer.usd(state.catalog, state.meta, cost_tokens) do
        {:ok, decimal} -> decimal
        {:error, _reason} -> nil
      end
    end
  end

  defp pricing_ready?(meta) do
    not is_nil(meta.provider) and is_binary(meta.resolved_model) and
      is_binary(meta.relationship_revision) and match?(%Date{}, meta.pricing_effective_date)
  end

  defp percent(tokens, limit) when is_integer(tokens) and is_integer(limit) and limit > 0 do
    round(tokens / limit * 100)
  end

  defp percent(_tokens, _limit), do: nil

  # ── throttle ─────────────────────────────────────────────────────────

  # Re-emit only when the context percent (integer) or whole-dollar spend
  # changes, so a long turn produces a bounded handful of status rows rather
  # than one per streamed cent. Both components are monotonic in practice.
  defp throttle_key(snapshot) do
    {snapshot.context.percent_used, usd_bucket(snapshot.cost.usd)}
  end

  defp usd_bucket(%Decimal{} = d), do: d |> Decimal.round(0, :down) |> Decimal.to_integer()
  defp usd_bucket(_other), do: nil

  # ── persistence ──────────────────────────────────────────────────────

  defp persist(snapshot, state) do
    JsonStore.write!(state.path, to_disk(snapshot, state))
    :ok
  rescue
    error ->
      Logger.warning("Cost.Store(#{state.identifier}) persist failed: " <> Exception.message(error))
      :ok
  end

  defp to_disk(snapshot, state) do
    %{
      "context" => %{
        "tokens" => snapshot.context.tokens,
        "limit" => snapshot.context.limit,
        "percent_used" => snapshot.context.percent_used
      },
      "cost" => %{
        "input_tokens" => snapshot.cost.input_tokens,
        "output_tokens" => snapshot.cost.output_tokens,
        "cached_input_tokens" => snapshot.cost.cached_input_tokens,
        "usd" => usd_to_number(snapshot.cost.usd)
      },
      "provider" => provider_string(state.meta.provider),
      "resolved_model" => state.meta.resolved_model,
      "threads" => state.threads,
      "active_thread" => state.active_thread,
      "meta" => meta_to_disk(state.meta),
      "last_updated_at" => snapshot.last_updated_at
    }
  end

  defp load_persisted(state) do
    case JsonStore.read(state.path) do
      {:ok, %{} = data} ->
        %{
          state
          | threads: normalize_threads(Map.get(data, "threads", %{})),
            meta: meta_from_disk(Map.get(data, "meta", %{})),
            active_thread: Map.get(data, "active_thread")
        }

      {:ok, nil} ->
        state

      {:error, reason} ->
        Logger.warning("Cost.Store(#{state.identifier}) corrupt file at #{state.path}: #{inspect(reason)}; starting empty")
        state
    end
  end

  defp normalize_threads(threads) when is_map(threads) do
    Map.new(threads, fn {id, t} ->
      {id, Map.merge(@empty_thread, Map.take(t, Map.keys(@empty_thread)))}
    end)
  end

  defp normalize_threads(_threads), do: %{}

  # ── meta helpers ─────────────────────────────────────────────────────

  defp empty_meta do
    %{provider: nil, resolved_model: nil, relationship_revision: nil, pricing_effective_date: nil, context_tier: nil}
  end

  defp merge_meta(existing, incoming) do
    Map.merge(existing, %{
      provider: incoming[:provider] || existing.provider,
      resolved_model: incoming[:resolved_model] || existing.resolved_model,
      relationship_revision: incoming[:relationship_revision] || existing.relationship_revision,
      pricing_effective_date: incoming[:pricing_effective_date] || existing.pricing_effective_date,
      context_tier: incoming[:context_tier] || existing.context_tier
    })
  end

  defp meta_to_disk(meta) do
    %{
      "provider" => provider_string(meta.provider),
      "resolved_model" => meta.resolved_model,
      "relationship_revision" => meta.relationship_revision,
      "pricing_effective_date" => date_string(meta.pricing_effective_date),
      "context_tier" => tier_string(meta.context_tier)
    }
  end

  defp meta_from_disk(data) when is_map(data) do
    %{
      provider: Map.get(@allowed_providers, Map.get(data, "provider")),
      resolved_model: Map.get(data, "resolved_model"),
      relationship_revision: Map.get(data, "relationship_revision"),
      pricing_effective_date: parse_date(Map.get(data, "pricing_effective_date")),
      context_tier: Map.get(@allowed_context_tiers, Map.get(data, "context_tier"))
    }
  end

  defp meta_from_disk(_data), do: empty_meta()

  defp provider_string(provider) when is_atom(provider) and not is_nil(provider), do: Atom.to_string(provider)
  defp provider_string(_provider), do: nil

  defp tier_string(tier) when is_atom(tier) and not is_nil(tier), do: Atom.to_string(tier)
  defp tier_string(_tier), do: nil

  defp date_string(%Date{} = date), do: Date.to_iso8601(date)
  defp date_string(_date), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp usd_to_number(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_float()
  defp usd_to_number(_other), do: nil

  # ── infra ────────────────────────────────────────────────────────────

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp via(identifier), do: {:via, Registry, {@registry, identifier}}

  defp registry_lookup(identifier) do
    Registry.lookup(@registry, identifier)
  rescue
    ArgumentError -> []
  end

  defp path_for(identifier) do
    safe = Paths.sanitize(identifier)
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.#{safe}.cost.json")
  end
end
