defmodule Aiur.Voice do
  @moduledoc """
  The provider-neutral voice seam.

  Callers start transcription and speech here and receive the neutral
  `:voice_*` owner messages documented on `Aiur.Voice.Transcriber` and
  `Aiur.Voice.Synthesizer`; none of them names a provider.

  The provider is the module under the `:voice_provider` application key. It
  holds a module, never a credential. `nil`, or a module that cannot be loaded,
  means no provider is installed.

  This module handles no audio beyond relaying it, writes nothing to disk or
  logs, returns no credential, and never delivers text to an agent.
  """

  @type reason :: nil | :unconfigured | :not_installed
  @type session :: %{pid: pid(), module: module()}

  @spec provider() :: module() | nil
  def provider do
    module = Application.get_env(:aiur, :voice_provider, Aiur.ElevenLabs)
    if is_atom(module) and module != nil and Code.ensure_loaded?(module), do: module
  end

  @spec availability() :: %{available: boolean(), reason: reason()}
  def availability do
    case provider() do
      nil -> %{available: false, reason: :not_installed}
      provider -> if configured?(provider), do: %{available: true, reason: nil}, else: %{available: false, reason: :unconfigured}
    end
  end

  @spec start_transcription(keyword()) :: {:ok, session()} | {:error, :not_installed | :unconfigured | term()}
  def start_transcription(opts) do
    with {:ok, provider} <- installed(),
         module = provider.transcriber(),
         {:ok, pid} <- module.start(opts) do
      {:ok, %{pid: pid, module: module}}
    end
  end

  # The session carries the transcriber it opened with, so a provider change
  # mid-session cannot redirect its audio.
  @spec push(session(), String.t()) :: :ok
  def push(%{pid: pid, module: module}, audio_base64), do: module.push(pid, audio_base64)

  @spec commit(session()) :: :ok
  def commit(%{pid: pid, module: module}), do: module.commit(pid)

  @spec stop(session()) :: :ok
  def stop(%{pid: pid, module: module}), do: module.stop(pid)

  @spec start_speech(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, :not_installed | atom()}
  def start_speech(owner, text, opts \\ []) do
    with {:ok, provider} <- installed(), do: provider.synthesizer().start(owner, text, opts)
  end

  defp installed do
    case provider() do
      nil -> {:error, :not_installed}
      provider -> {:ok, provider}
    end
  end

  # A provider whose credential cannot be read cannot be used.
  defp configured?(provider) do
    provider.configured?() == true
  rescue
    _unavailable -> false
  catch
    _kind, _reason -> false
  end
end
