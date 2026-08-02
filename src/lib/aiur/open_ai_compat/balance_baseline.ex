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
    (`balance-baseline.json`) beside the active workflow configuration, so it
    survives restarts. The observation that seeds the baseline renders
    dollar-only (there is no consumption evidence yet); used percent appears
    from the next observation onward.
  * **Explicit initial deposit.** An operator may set
    `agent.backend_configs.<provider>.balance_baseline` (USD) in the aiur
    config. When present it takes precedence over any persisted baseline, so a
    prepaid account that predates the feature (or was topped up) reads a
    truthful percentage immediately without waiting for a fresh seeding.

  A provider with no baseline (and no configured deposit) keeps the current
  dollar-only rendering and never fabricates a percentage.
  """

  alias Aiur.{Config, Workflow}

  @file_name "balance-baseline.json"
  @baselines_key "baselines"

  @spec path() :: Path.t()
  def path, do: Path.join(Path.dirname(Workflow.workflow_file_path()), @file_name)

  @doc """
  The effective baseline amount for `provider`, or `nil` when none can be
  established.

  Returns `{amount, freshly_seeded?}`. When an explicit configured initial
  deposit is present it wins (not freshly seeded). Otherwise a persisted
  baseline is used; with neither, the first *positive* observed balance is
  seeded and persisted as the baseline (`freshly_seeded?` true). A zero first
  observation establishes nothing (there is no original deposit to infer from)
  so a later positive observation can still seed.
  """
  @spec resolve(atom(), number(), keyword()) :: {number(), boolean()} | nil
  def resolve(provider, observed_balance, opts \\ []) when is_number(observed_balance) and observed_balance >= 0 do
    case configured_deposit(provider, opts) do
      {:ok, amount} -> {amount, false}
      :error -> persisted_or_seed(provider, observed_balance, Keyword.get(opts, :path, path()))
    end
  end

  @doc "The persisted baseline amount for `provider`, or `nil` when none."
  @spec persisted_baseline(atom(), Path.t()) :: number() | nil
  def persisted_baseline(provider, path \\ path()) do
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
      nil when observed_balance > 0 -> {seed(provider, observed_balance, path), true}
      nil -> nil
      baseline -> {baseline, false}
    end
  end

  defp seed(provider, observed_balance, path) do
    :global.trans({__MODULE__, path}, fn ->
      state = load(path)
      baselines = Map.get(state, @baselines_key, %{})

      entry = %{
        "amount" => observed_balance,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      write(path, Map.put(state, @baselines_key, Map.put(baselines, Atom.to_string(provider), entry)))
    end)

    observed_balance
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = state} <- Jason.decode(body) do
      state
    else
      _ -> %{}
    end
  end

  defp write(path, state) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state, pretty: true))
  end
end
