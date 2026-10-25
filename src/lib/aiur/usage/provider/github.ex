defmodule Aiur.Usage.Provider.GitHub do
  @moduledoc false
  alias Aiur.GitHub.Quota
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}

  @spec read(keyword()) :: t()
  def read(opts) do
    snapshot = Keyword.get_lazy(opts, :github_quota, &Quota.snapshot/0)
    observed = Map.get(snapshot, :state) == :observed

    observed_at =
      snapshot
      |> Map.get(:windows, %{})
      |> Map.values()
      |> Enum.map(&Map.get(&1, :observed_at))
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> Enum.reduce(nil, fn date, latest ->
        if is_nil(latest) or DateTime.compare(date, latest) == :gt, do: date, else: latest
      end)

    ProviderSupport.record(
      __MODULE__,
      :github,
      observed_at,
      if(observed, do: :fresh, else: :unknown),
      %{windows: Map.get(snapshot, :windows, %{}), reconciliation: Map.get(snapshot, :reconciliation, %{})},
      "github.quota"
    )
  end
end
