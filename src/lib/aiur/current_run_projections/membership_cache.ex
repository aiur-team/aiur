defmodule Aiur.CurrentRunProjections.MembershipCache do
  @moduledoc false

  @spec get(map(), term(), term(), list()) :: map()
  def get(
        %{
          run_id: run_id,
          membership_generation: generation,
          membership_index: %{by_locator: by_locator, signature: signature} = index
        },
        run_id,
        generation,
        _members
      )
      when is_map(by_locator) and is_binary(signature),
      do: index

  def get(state, _run_id, _generation, members),
    do: state.membership_index_fun.(members)
end
