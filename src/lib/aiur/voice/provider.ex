defmodule Aiur.Voice.Provider do
  @moduledoc """
  A voice provider: the one module `Aiur.Voice` resolves, naming the modules
  that transcribe and speak.

  `configured?/0` reports only whether a credential is present. The credential
  itself never leaves the provider.
  """

  @doc "The module implementing `Aiur.Voice.Transcriber`."
  @callback transcriber() :: module()

  @doc "The module implementing `Aiur.Voice.Synthesizer`."
  @callback synthesizer() :: module()

  @doc "Whether a credential is present. Never returns the credential."
  @callback configured?() :: boolean()
end
