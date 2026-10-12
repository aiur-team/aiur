defmodule Aiur.GitHub.EventTrust do
  @moduledoc """
  Default `Aiur.Events.TrustClassifier`: asks `Aiur.GitHub.CodeOwners`, the
  single trust authority. `false` when it is not running (early boot, tests).
  """

  @behaviour Aiur.Events.TrustClassifier

  alias Aiur.GitHub.CodeOwners

  @impl true
  def trusted?(author) when is_binary(author) do
    if Process.whereis(CodeOwners), do: CodeOwners.allowed?(author), else: false
  end
end
