defmodule Aiur.Commands.NativeCapture.Claude do
  @moduledoc "Translate Claude native requests into deferred Commands."

  alias Aiur.Commands.NativeCapture.Request
  alias Aiur.Config

  @spec handle(port() | pid(), term(), map(), map()) :: term()
  def handle(port, id, params, ctx) do
    if Config.decisions_native_capture?(:claude), do: Request.capture(port, id, params, ctx, :claude), else: :unhandled
  end
end
