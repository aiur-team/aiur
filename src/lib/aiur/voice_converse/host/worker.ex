defmodule Aiur.VoiceConverse.Host.Worker do
  @moduledoc """
  Trusted worker target for the Aiur voice host. Construct from the selected worker's
  tracker identity and, when available, its exact live-conversation source.
  This is an internal provider-context target, not a device read API.
  """
  @enforce_keys [:identity]
  defstruct [:identity, :live_source]

  @type t :: %__MODULE__{identity: Aiur.TrackerIdentity.t(), live_source: Aiur.LiveConversation.source() | nil}
end
