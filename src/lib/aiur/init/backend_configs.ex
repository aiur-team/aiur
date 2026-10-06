defmodule Aiur.Init.BackendConfigs do
  @moduledoc "Provider-owned onboarding prompts and config collected through backend descriptors."

  alias Aiur.CodingAgent

  @spec prompt(Aiur.Init.io(), [String.t()], map()) :: map()
  def prompt(io, selected, descriptors \\ CodingAgent.backends()) do
    Enum.reduce(selected, %{}, fn backend, acc ->
      descriptor = Map.fetch!(descriptors, backend)

      case Map.get(descriptor, :init) do
        nil -> acc
        init -> Map.put(acc, backend, init.prompt(io))
      end
    end)
  end

  @spec config([String.t()], map(), map()) :: map()
  def config(selected, answers, descriptors \\ CodingAgent.backends()) do
    Enum.reduce(selected, %{}, fn backend, acc ->
      descriptor = Map.fetch!(descriptors, backend)

      case Map.get(descriptor, :init) do
        nil -> acc
        init -> Map.put(acc, backend, init.config(Map.fetch!(answers, backend)))
      end
    end)
  end
end
