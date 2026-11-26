defmodule Aiur.TicketActivity.Projection.Publication do
  @moduledoc false

  alias Aiur.TicketActivity.Projection
  alias Aiur.TrackerIdentity

  @spec reading(Projection.t(), TrackerIdentity.t()) :: map() | nil
  def reading(%Projection{} = state, %TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      nil ->
        nil

      entry_key ->
        case Map.get(state.entries, entry_key) do
          %{progress: progress, stage: stage} when is_map(progress) ->
            %{progress: progress, stage: stage}

          _ ->
            nil
        end
    end
  end

  def reading(_state, _identity), do: nil
end
