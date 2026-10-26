defmodule Aiur.ModelAvailability.Presentation do
  @moduledoc false

  alias Aiur.ModelAvailability

  @spec provider_freshness_detail([String.t()], keyword()) :: String.t()
  def provider_freshness_detail(backends, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, ModelAvailability.load(Keyword.get(opts, :path, ModelAvailability.path())))

    details =
      backends
      |> Enum.map(&ModelAvailability.backend_key/1)
      |> Enum.uniq()
      |> Enum.map(fn backend ->
        entry = get_in(state, ["backends", backend]) || %{}
        observed_at = Map.get(entry, "observed_at", "unknown")

        freshness =
          cond do
            not Map.has_key?(entry, "observed_at") -> "unknown"
            ModelAvailability.stale?(backend, state: state, now: now) -> "stale"
            true -> "fresh"
          end

        next_probe = Map.get(entry, "retry_scheduled_at", "unknown")
        "#{backend}=#{freshness} observed_at=#{observed_at} next_probe=#{next_probe}"
      end)

    "backends=" <> Enum.join(details, "; ")
  end
end
