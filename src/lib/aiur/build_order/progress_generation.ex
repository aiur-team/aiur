defmodule Aiur.BuildOrder.ProgressGeneration do
  @moduledoc "Assigns Build Order generations from durable milestone latches."

  @spec assign(map(), map() | nil, map() | nil) :: map()
  def assign(%{scope: {:build_order, id}} = fact, latches, previous) do
    generations =
      for {key, milestone} <- latches || %{}, {:ok, ["build_order", ^id, generation]} <- [Jason.decode(key)], is_integer(generation), do: {generation, milestone}

    {generation, milestone} = Enum.max_by(generations, &elem(&1, 0), fn -> {1, 0} end)
    generation = max(generation, if(previous, do: previous.generation, else: 1))
    reopened? = milestone == 100 and fact.resolution == :resolved and is_number(fact.percent) and fact.percent < 100
    Map.put(fact, :generation, if(reopened?, do: generation + 1, else: generation))
  end
end
