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

  @doc "Supervision children owned by this provider, in boot order."
  @callback child_specs() :: [Supervisor.child_spec() | module() | {module(), term()}]

  @doc "The account quota observation consumed by the credits row."
  @callback quota_snapshot() :: map()

  @doc "Whether a credential is present. Never returns the credential."
  @callback configured?() :: boolean()
end
