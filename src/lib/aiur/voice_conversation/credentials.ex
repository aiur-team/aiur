defmodule Aiur.VoiceConversation.Credentials do
  @moduledoc "Compatibility entry point for voice provider credentials."
  @behaviour VoiceConverse.Ports.Credentials

  @impl true
  defdelegate fetch(provider, purpose), to: Aiur.VoiceConverse.Host.Credentials
end
