defmodule Aiur.Events.TrustClassifier do
  @moduledoc """
  Port the event-payload sanitizer uses to decide `author_trusted?`.

  Defines no trust rules: the implementation configured under
  `config :aiur, Aiur.Events.TrustClassifier` delegates to the trust
  authority. Implementations must fail closed (never default to `true`).
  """

  @callback trusted?(author :: String.t()) :: boolean()
end
