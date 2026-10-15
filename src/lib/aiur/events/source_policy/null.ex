defmodule Aiur.Events.SourcePolicy.Null do
  @moduledoc "Source-neutral publication policy for a bus with no configured source gates."
  @behaviour Aiur.Events.SourcePolicy

  @impl true
  def self_authored?(_topic, _actor, _payload), do: false

  @impl true
  def already_processed?(_opts), do: false

  @impl true
  def mark_processed(_opts), do: :ok

  @impl true
  def observe(_outcome, _opts), do: :ok
end
