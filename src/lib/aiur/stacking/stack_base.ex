defmodule Aiur.Stacking.StackBase do
  @moduledoc "Pure base decision using only direct blockers and their PR evidence."

  @spec decide(String.t() | nil, String.t(), [map()]) :: {:ok, :integration | {:stacked, String.t()}} | {:repair, String.t()}
  def decide(current_base, integration_branch, blockers) do
    cond do
      current_base == integration_branch -> {:ok, :integration}
      blocker = Enum.find(blockers, &open_base?(&1, current_base)) -> {:ok, {:stacked, blocker.id}}
      true -> {:repair, integration_branch}
    end
  end

  defp open_base?(%{id: id, pr: %{state: :open, merged?: false, head_ref: ref}}, base)
       when is_binary(id) and id != "" and is_binary(ref) and ref != "", do: ref == base

  defp open_base?(_blocker, _base), do: false
end
