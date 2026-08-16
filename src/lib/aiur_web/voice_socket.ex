defmodule AiurWeb.VoiceSocket do
  @moduledoc """
  Socket for dashboard dictation audio.

  The browser cannot run the #1930 Node/PipeWire capture path, so it streams
  raw PCM here over a plain Phoenix channel; the server owns the ElevenLabs
  session. Authentication is the same session proof the LiveView dashboard
  uses: the browser already holds a signed dashboard session (basic auth ->
  `FinancialDataAccess`), and this socket verifies it before any channel join
  is admitted.
  """

  use Phoenix.Socket

  alias AiurWeb.FinancialDataAccess

  channel("voice:dictation", AiurWeb.VoiceChannel)
  channel("voice:conversation", AiurWeb.VoiceChannel)

  @impl true
  def connect(%{"_csrf_token" => csrf_token}, socket, %{session: session})
      when is_binary(csrf_token) and is_map(session) do
    with true <- AiurWeb.Endpoint.config(:dashboard_writable),
         true <- Plug.CSRFProtection.valid_state_and_csrf_token?(session["_csrf_token"], csrf_token),
         {:ok, context} <- FinancialDataAccess.context_from_session(session),
         :ok <- FinancialDataAccess.authorize(context) do
      {:ok,
       assign(socket, :voice_authority, %{
         configuration_generation: context.configuration_generation,
         connection_generation: context.connection_generation
       })}
    else
      _read_only_or_invalid -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
