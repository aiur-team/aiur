defmodule Aiur.ElevenLabs.Realtime.Transport do
  @moduledoc """
  The one network boundary of a realtime transcription session.

  `Aiur.ElevenLabs.Realtime` owns every decision — readiness, backlog, which
  message types are final, when to flush — and this behaviour owns only the
  bytes. That split is what lets the whole protocol be tested without a socket
  and without a clock.

  A transport delivers inbound frames to the process that called `connect/2`,
  as plain messages:

    * `{:elevenlabs_transport, :text, binary}` — one decoded text frame
    * `{:elevenlabs_transport, :closed}` — the peer closed
    * `{:elevenlabs_transport, :error, term}` — the connection failed

  The `term` on `:error` is never rendered. A transport error can embed the
  request that produced it, and the request carries the `xi-api-key` header, so
  the session discards it and describes the failure generically.
  """

  @callback connect(url :: String.t(), headers :: [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  @callback send_text(conn :: term(), text :: String.t()) :: {:ok, term()} | {:error, term()}
  @callback close(conn :: term()) :: :ok
end
