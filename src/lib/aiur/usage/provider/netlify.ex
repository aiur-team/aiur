defmodule Aiur.Usage.Provider.Netlify do
  @moduledoc false
  alias Aiur.Netlify.Usage
  alias Aiur.Usage.ProviderSupport
  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}
  @spec read(keyword()) :: t()
  def read(opts) do
    snapshot = Keyword.get_lazy(opts, :netlify_usage, &Usage.snapshot/0)

    ProviderSupport.record(__MODULE__, :netlify, Map.get(snapshot, :observed_at), Map.get(snapshot, :freshness, :unknown), Map.take(snapshot, [:state, :reason, :fields]), "netlify.usage")
    |> Map.put(:age_ms, Map.get(snapshot, :age_ms))
    |> Map.put(:freshness, Map.get(snapshot, :freshness, :unknown))
  catch
    :exit, _ -> ProviderSupport.record(__MODULE__, :netlify, nil, :unknown, %{state: :unavailable, reason: :service_unavailable}, "netlify.usage")
  end
end
