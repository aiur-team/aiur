defmodule Aiur.Usage.Provider.Ticket do
  @moduledoc false
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}

  @spec read(keyword()) :: t()
  def read(opts) do
    snapshot = Keyword.get_lazy(opts, :ticket_usage, &Aiur.UsageAggregate.snapshot/0)
    freshness = Map.get(snapshot, :freshness, %{})

    ProviderSupport.record(
      __MODULE__,
      :ticket,
      Map.get(freshness, :observed_at),
      Map.get(freshness, :status, :unknown),
      %{aggregate: snapshot},
      "usage.aggregate"
    )
  rescue
    _ -> ProviderSupport.record(__MODULE__, :ticket, nil, :unknown, %{aggregate: nil}, "usage.aggregate")
  end
end
