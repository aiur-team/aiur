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

  alias Aiur.{CodingAgent, ProviderMeterProjection}
  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.FinancialData

  @server AiurWeb.FinancialData
  @max_age_ms 5_000

  @type context :: term()
  @type snapshots :: %{optional(atom()) => ProviderMeterSnapshot.t() | nil}

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
    Map.new(CodingAgent.provider_families(), fn provider ->
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

  # Read the daemon-owned projection rather than the binding-scoped store.
  #
  # Bindings are minted per session and held in that session's process
  # dictionary, so no daemon-wide binding exists for a web connection to
  # resolve — a binding-scoped read here could only ever produce the
  # unknown-identity snapshot, which is why meters never rendered. The
  # projection retains accepted observations and hands back the same struct
  # with the account generation projected out, so this layer needs no
  # capability at all.
  #
  # Authorization is unchanged: the read still happens inside the facade's
  # loader closure, so a denied context never reaches the projection.
  defp snapshot(provider, _binding), do: ProviderMeterProjection.redacted_snapshot(provider)

  # Retained so the facade's loader signature stays stable; the projection is
  # binding-free, so there is nothing to resolve.
  defp provider_binding(_provider), do: nil

  defp key(provider), do: {:provider_meter, provider}
end
