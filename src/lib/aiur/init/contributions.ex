defmodule Aiur.Init.Contributions do
  @moduledoc "Ordered setup contributions supplied by installed components."

  @spec registered!() :: [map()]
  def registered! do
    case Application.fetch_env(:aiur, :init_contributions) do
      {:ok, modules} when is_list(modules) ->
        modules |> Enum.map(& &1.init_contribution()) |> Enum.reject(&is_nil/1)

      _ ->
        :erlang.error({:error, :init_contributions_unregistered})
    end
  end

  @spec prompt(Aiur.Init.io(), Aiur.Init.deps(), atom()) :: map()
  def prompt(io, deps, location) do
    Map.new(registered!(), fn contribution ->
      {contribution.id, contribution.prompt.(io, deps, location)}
    end)
  end

  @spec summary_lines(map()) :: [String.t() | nil]
  def summary_lines(config), do: Enum.map(registered!(), & &1.resume.(config))

  @spec yaml(map()) :: String.t()
  def yaml(data) do
    answers = Map.get(data, :contributions, data)

    Enum.map_join(registered!(), "", fn contribution ->
      "\n" <> IO.iodata_to_binary(contribution.yaml.(Map.fetch!(answers, contribution.id)))
    end)
  end
end
