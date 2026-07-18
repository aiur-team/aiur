defmodule AiurWeb.OperatorControlCenter.ProviderMeterSource do
  @moduledoc """
  Loads protected Codex and Claude provider-meter snapshots for the Units page
  strictly through the DASH-021 `AiurWeb.FinancialData` facade.

  Every read is a loader closure passed to the facade, so authorization is
  re-verified before `Aiur.ProviderMeters` is ever touched and a denied context
  yields no snapshot and no provider invocation. Each provider is loaded and
  degraded independently, so one provider's facade error never affects the
  other card.

  The daemon owns which account binding backs each provider. Until a
  consumer-facing binding is resolved, a provider with no binding degrades to
  the explicit unknown-identity snapshot rather than borrowing another
  account's facts.
  """

  alias Aiur.ProviderMeters
  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.FinancialData

  @server AiurWeb.FinancialData
  @providers [:codex, :claude]
  @backend :app_server
  @max_age_ms 5_000

  @type context :: term()
  @type snapshots :: %{codex: ProviderMeterSnapshot.t() | nil, claude: ProviderMeterSnapshot.t() | nil}

  @doc """
  Fetch current protected snapshots for every provider after authorization.

  `opts[:snapshot_fun]` overrides the daemon read for tests; it is only ever
  invoked from inside the facade loader closure, so a denied context never
  reaches it.
  """
  @spec load(context(), keyword()) :: snapshots()
  def load(context, opts \\ []) do
    snapshot_fun = snapshot_fun(opts)

    fetch_all(fn provider, binding ->
      FinancialData.fetch_provider_meter(@server, context, key(provider), @max_age_ms, loader(provider, binding, snapshot_fun))
    end)
  end

  @doc """
  Reload snapshots in response to a payload-free facade update `message`,
  revalidating that the message matches the connection identity before reading.
  """
  @spec reload(context(), term(), keyword()) :: snapshots()
  def reload(context, message, opts \\ []) do
    snapshot_fun = snapshot_fun(opts)

    fetch_all(fn provider, binding ->
      FinancialData.reload(@server, context, message, :provider_meter, key(provider), @max_age_ms, loader(provider, binding, snapshot_fun))
    end)
  end

  @doc "Subscribe the authorized connection to daemon-owned meter updates."
  @spec subscribe(context()) :: :ok | {:error, term()}
  def subscribe(context), do: FinancialData.subscribe(context)

  defp snapshot_fun(opts), do: Keyword.get(opts, :snapshot_fun, &snapshot/2)

  defp fetch_all(fetch) do
    Map.new(@providers, fn provider ->
      {provider, fetch_one(provider, fetch)}
    end)
  end

  defp fetch_one(provider, fetch) do
    case fetch.(provider, provider_binding(provider)) do
      {:ok, %ProviderMeterSnapshot{} = snapshot} -> snapshot
      _denied_or_unavailable -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp loader(provider, binding, snapshot_fun), do: fn -> snapshot_fun.(provider, binding) end

  # `ProviderMeters.snapshot/3` always returns a struct, so a resolvable binding
  # produces the account's projection and an unresolved binding produces the
  # explicit unknown-identity snapshot without reaching the store with a nil
  # binding.
  defp snapshot(provider, nil), do: ProviderMeterSnapshot.unknown(provider, @backend)
  defp snapshot(provider, binding), do: ProviderMeters.snapshot(provider, @backend, binding)

  # No consumer-facing accessor exposes the daemon's active binding yet; a
  # provider without one renders the explicit unknown-identity state.
  defp provider_binding(_provider), do: nil

  defp key(provider), do: {:provider_meter, provider}
end
