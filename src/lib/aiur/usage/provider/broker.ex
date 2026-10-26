defmodule Aiur.Usage.Provider.Broker do
  @moduledoc false
  alias Aiur.GitHub.Access
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}

  @spec read(keyword()) :: t()
  def read(opts) do
    result = Keyword.get_lazy(opts, :broker_usage, &Access.usage/0)
    actors = Map.get(result, :actors)
    observed? = is_list(actors) and actors != []

    ProviderSupport.record(
      __MODULE__,
      :broker,
      if(observed?, do: DateTime.utc_now(), else: nil),
      if(observed?, do: :fresh, else: :unknown),
      %{actors: actors},
      "github.broker"
    )
  end
end
