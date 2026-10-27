defmodule Aiur.Commands.NativeCapture.Codex do
  @moduledoc "Gated translation of native user-input requests into held Commands."

  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.NativeCapture.Request
  alias Aiur.Config

  @spec handle(port() | pid(), term(), map(), map()) :: :unhandled | :approved | :input_required | {:held, String.t(), map()} | {:error, :port_closed}
  def handle(port, id, params, ctx) do
    if Config.decisions_native_capture?(:codex) do
      Request.capture(port, id, params, ctx, :codex)
    else
      :unhandled
    end
  end

  @doc "Reply to a held JSON-RPC user-input request with all structured answers."
  @spec reply(port() | pid(), term(), map()) :: :ok | {:error, :port_closed}
  defdelegate reply(port, request_id, answers), to: UserInputAnswers
end
