defmodule Aiur.Intent.Publish do
  @moduledoc "Pushes a just-written change to the shared store and says whether it landed."

  alias Aiur.Intent.{Change, Store, Sync}

  # Sync.sync_once pushes the outbox; whatever is still in it was not stored.
  @spec push(Change.t()) :: :stored | :outbox_only
  def push(change) do
    _ = Sync.sync_once()
    if Enum.any?(Store.outbox(), &(&1.change_id == change.change_id)), do: :outbox_only, else: :stored
  catch
    :exit, _ -> :outbox_only
  end
end
