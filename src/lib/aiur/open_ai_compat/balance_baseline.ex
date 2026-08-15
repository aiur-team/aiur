defmodule Aiur.OpenAICompat.BalanceBaseline do
  @moduledoc """
  Durable prepaid-balance baseline for OpenAI-compatible providers.

  The DeepSeek balance endpoint returns only the current remaining balance,
  never the original deposit, so a spend percentage cannot be derived from a
  single reading. This module establishes and persists a baseline so the meter
  can render an honest `used% = (baseline - remaining) / baseline`.

  Two seeding approaches are supported:

  * **First-observed baseline (default).** The first positive observed balance
    is recorded as the baseline and persisted in a JSON ledger
    (`balance-baseline.json`) under the daemon-private state directory (see
    `Aiur.Config.Paths.balance_baseline_state_dir/0`), so it survives restarts
    and never pollutes a repo-checked-in config directory. The observation that
    seeds the baseline renders dollar-only (there is no consumption evidence
    yet); used percent appears from the next observation onward. A persisted
    baseline that has fallen *below* the observed balance is stale by
    definition and is reseeded in place (see `resolve/3`).
  * **Explicit initial deposit.** An operator may set
    `agent.backend_configs.<provider>.balance_baseline` (USD) in the aiur
    config. When present it takes precedence over any persisted baseline, so a
    prepaid account that predates the feature (or was topped up) reads a
    truthful percentage immediately without waiting for a fresh seeding.

  Persistence is best-effort: a baseline write that fails (read-only mount,
  full disk) degrades to "no baseline → dollar-only" and never takes down the
  meter probe. A provider with no baseline (no configured deposit and no
  durable location) keeps the current dollar-only rendering and never
  fabricates a percentage.
  """

  require Logger

  alias Aiur.Config

  @file_name "balance-baseline.json"
  @baselines_key "baselines"

  # A balance is dollars-and-cents, so anything under a cent above the baseline
  # is float noise or a rounding artifact, not a top-up. Reseeding on it would
  # rewrite the ledger (and take the global lock) on every probe cycle while
  # holding the meter permanently at "no consumption evidence yet".
  @reseed_epsilon 0.01

  @spec path() :: Path.t() | nil
  def path do
    case Config.Paths.balance_baseline_state_dir() do
      {:ok, dir} -> Path.join(dir, @file_name)
      _ -> nil
    end
  end

  @doc """
  The effective baseline amount for `provider`, or `nil` when none can be
  established.

  Returns `{amount, freshly_seeded?}`. When an explicit configured initial
  deposit is present it wins (not freshly seeded). Otherwise a persisted
  baseline is used; with neither, the first *positive* observed balance is
  seeded and persisted as the baseline (`freshly_seeded?` true). A zero first
  observation establishes nothing (there is no original deposit to infer from)
  so a later positive observation can still seed. If no durable location is
  available (or persistence fails) the call returns `nil`, keeping the
  dollar-only rendering.

  A persisted baseline *below* the observed balance is stale by definition:
  spend is `baseline - remaining`, so a remaining balance above the baseline
  would mean negative consumption, which cannot happen. The only thing that
  produces it is a top-up recorded after the baseline was. Such a baseline is
  reseeded to the observed balance and persisted, so the meter re-anchors on
  the next observation instead of pinning itself at 0% (or requiring an
  operator to delete the ledger by hand). A reseed carries no consumption
  evidence, so it reports `freshly_seeded?` true and renders dollar-only,
  exactly like a first seeding.
  """
  @spec resolve(atom(), number(), keyword()) :: {number(), boolean()} | nil
  def resolve(provider, observed_balance, opts \\ []) when is_number(observed_balance) and observed_balance >= 0 do
    case configured_deposit(provider, opts) do
      {:ok, amount} ->
        # A configured deposit below the observed balance is stale for exactly
        # the same reason a persisted one is, but it is the operator's
        # declaration and this module does not rewrite the aiur config. So it
        # is honored (the clamp keeps it at 0%) and reported, naming the key to
        # update, rather than silently reading as "nothing spent" forever.
        if stale?(amount, observed_balance) do
          warn_stale_deposit(provider, amount, observed_balance)
        end

        {amount, false}

      :error ->
        case Keyword.get(opts, :path, path()) do
          nil -> nil
          path -> persisted_or_seed(provider, observed_balance, path)
        end
    end
  end

  @doc "The persisted baseline amount for `provider`, or `nil` when none."
  @spec persisted_baseline(atom(), Path.t()) :: number() | nil
  def persisted_baseline(provider, path \\ path()) when is_binary(path) do
    case get_in(load(path), [@baselines_key, Atom.to_string(provider)]) do
      %{"amount" => amount} when is_number(amount) and amount > 0 -> amount
      _ -> nil
    end
  end

  @doc """
  The explicit `agent.backend_configs.<provider>.balance_baseline` (USD)
  deposit, when configured. `opts` may carry a `:backend_configs` map (the
  probe's injected test seam); otherwise the live aiur settings are read.
  """
  @spec configured_deposit(atom(), keyword()) :: {:ok, number()} | :error
  def configured_deposit(provider, opts \\ []) do
    provider_config = provider_config(provider, opts)

    case Map.get(provider_config, "balance_baseline") || Map.get(provider_config, :balance_baseline) do
      amount when is_number(amount) and amount > 0 -> {:ok, amount}
      _ -> :error
    end
  end

  defp provider_config(provider, opts) do
    backend_configs = backend_configs(opts)
    Map.get(backend_configs, Atom.to_string(provider)) || Map.get(backend_configs, provider) || %{}
  end

  defp backend_configs(opts) do
    case Keyword.fetch(opts, :backend_configs) do
      {:ok, config} -> config
      :error -> safe_backend_configs()
    end
  end

  defp safe_backend_configs do
    Config.agent_backend_configs()
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp persisted_or_seed(provider, observed_balance, path) do
    case persisted_baseline(provider, path) do
      # The normal spending case, and a seeding observation read back: the
      # baseline is still a valid anchor, so measure against it.
      baseline when is_number(baseline) ->
        if stale?(baseline, observed_balance) do
          reseed_or_dollar_only(provider, observed_balance, path)
        else
          {baseline, false}
        end

      nil ->
        reseed_or_dollar_only(provider, observed_balance, path)
    end
  end

  # Missing, or stale (meaningfully below the observed balance) after a top-up.
  # Either way this observation is the best anchor available — unless it is
  # zero or negative, which is no anchor at all: it establishes nothing, and a
  # later positive observation can still seed.
  defp reseed_or_dollar_only(provider, observed_balance, path) when observed_balance > 0 do
    seed_result(seed(provider, observed_balance, path))
  end

  defp reseed_or_dollar_only(_provider, _observed_balance, _path), do: nil

  defp stale?(baseline, observed_balance), do: observed_balance - baseline > @reseed_epsilon

  # The probe runs on a timer, so an unconditional log here would repeat every
  # cycle for as long as the config stays wrong. Key the warning on the value
  # that is wrong: it is emitted once per configured amount, and again if the
  # operator changes it to another stale one.
  defp warn_stale_deposit(provider, amount, observed_balance) do
    key = {__MODULE__, :stale_deposit_warned, provider, amount}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "configured balance_baseline is below the observed balance provider=#{inspect(provider)} " <>
          "configured=#{amount} observed=#{observed_balance} — spend cannot be measured against it; " <>
          "update agent.backend_configs.#{provider}.balance_baseline or remove it to let the meter reseed itself"
      )
    end

    :ok
  end

  # A failed write degrades to dollar-only rather than crashing the probe.
  # Deliberately not a catch-all: `:global.trans/2` retries forever rather than
  # aborting, so there is no third return to absorb, and a wildcard here would
  # silently swallow a future shape change out of `seed/3`.
  defp seed_result({:ok, amount, seeded?}), do: {amount, seeded?}
  defp seed_result(:error), do: nil

  # The lock id is `{ResourceId, LockRequesterId}`, and `:global` grants a lock
  # whose requester id *matches* the one already held. Keying the requester on
  # the path (`{__MODULE__, path}`) therefore inverted the intent exactly: two
  # probes on the same ledger both took the lock, while two on different
  # ledgers — sharing `__MODULE__` as the resource — blocked each other. The
  # ledger is read-modify-written whole, so a lost race drops another
  # provider's entry.
  defp seed(provider, observed_balance, path) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      state = load(path)
      baselines = Map.get(state, @baselines_key, %{})

      # Re-read under the lock, because the caller's staleness check ran outside
      # it and a concurrent writer may have moved the baseline since.
      seed_under_lock(state, baselines, provider, observed_balance, path)
    end)
  end

  defp seed_under_lock(state, baselines, provider, observed_balance, path) do
    case Map.get(baselines, Atom.to_string(provider)) do
      %{"amount" => existing} when is_number(existing) and existing > 0 ->
        if stale?(existing, observed_balance) do
          reseed(state, baselines, provider, existing, observed_balance, path)
        else
          {:ok, existing, false}
        end

      _missing ->
        write_entry(state, baselines, provider, entry(observed_balance), path, observed_balance)
    end
  end

  # Replacing the anchor discards the only record of what spend was being
  # measured against, so the previous amount is kept in the entry and the move
  # is logged. A reseed is not routine — it means the account was topped up, or
  # that the provider reported a balance it should not have — and an operator
  # who sees the percentage restart needs to be able to find out which.
  defp reseed(state, baselines, provider, previous, observed_balance, path) do
    Logger.info(
      "balance baseline reseeded provider=#{inspect(provider)} previous=#{previous} observed=#{observed_balance} " <>
        "reason=observed_balance_above_baseline"
    )

    entry =
      observed_balance
      |> entry()
      |> Map.merge(%{"previous_amount" => previous, "reseeded_at" => timestamp()})

    write_entry(state, baselines, provider, entry, path, observed_balance)
  end

  defp entry(observed_balance), do: %{"amount" => observed_balance, "recorded_at" => timestamp()}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Persist a seeded or reseeded baseline entry. Best-effort: a failed write
  # returns `:error` so the meter degrades to dollar-only instead of raising
  # through the probe.
  defp write_entry(state, baselines, provider, entry, path, observed_balance) do
    updated = Map.put(state, @baselines_key, Map.put(baselines, Atom.to_string(provider), entry))

    case write(path, updated) do
      :ok -> {:ok, observed_balance, true}
      :error -> :error
    end
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = state} <- Jason.decode(body) do
      state
    else
      _ -> %{}
    end
  end

  # Best-effort persistence: a write that raises (read-only mount, full disk,
  # path is a directory, or an intermediate directory that cannot be created)
  # must never take down the whole meter probe, so it degrades to
  # "no baseline → dollar-only". `File.mkdir_p!/1` is inside the guard for the
  # same reason `File.write!/1` is: a `mkdir` that fails (read-only mount) is
  # exactly the failure this module promises to contain, not to propagate.
  defp write(path, state) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state, pretty: true))
    :ok
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
