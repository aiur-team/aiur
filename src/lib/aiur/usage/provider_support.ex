defmodule Aiur.Usage.ProviderSupport do
  @moduledoc false

  @spec record(module(), atom(), DateTime.t() | nil, atom(), map(), String.t()) :: struct()
  def record(module, provider, observed_at, freshness, fields, source) do
    struct(module,
      provider: provider,
      observed_at: observed_at,
      age_ms: age_ms(observed_at),
      freshness: freshness,
      source: source,
      fields: fields
    )
  end

  @spec meter(module(), atom(), keyword()) :: struct()
  def meter(module, provider, opts) do
    views = Keyword.get_lazy(opts, :meter_views, &Aiur.ProviderMeterProjection.snapshot/0)
    view = Map.get(views, provider, %{state: :unknown, observed_at: nil, freshness: :unknown})

    record(
      module,
      provider,
      Map.get(view, :observed_at),
      Map.get(view, :freshness, :unknown),
      Map.drop(view, [:provider, :observed_at, :freshness, :age_seconds]),
      "provider_meter_projection"
    )
  rescue
    _ -> record(module, provider, nil, :unknown, %{}, "provider_meter_projection")
  end

  @spec age_ms(term()) :: non_neg_integer() | nil
  def age_ms(%DateTime{} = date), do: max(DateTime.diff(DateTime.utc_now(), date, :millisecond), 0)
  def age_ms(_), do: nil
end
