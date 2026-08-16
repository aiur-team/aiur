defmodule Aiur.ProviderMeters.ProbeCrash do
  @moduledoc """
  The failure reason for "the meter probe itself raised", kept distinct from
  the reasons that mean "the provider did not answer".

  Every meter probe wraps itself in a blanket `rescue`/`catch` so a provider
  quirk can never take the daemon down. That containment used to flatten *any*
  exception onto `:probe_failed` — the same reason a genuine outage, a dead
  socket, or a killed probe task reports. The two are not the same failure and
  do not have the same fix: an outage is waited out, a raise is a bug in our
  own code on a response we did receive.

  Conflating them is not theoretical. A one-line type error in the DeepSeek
  balance percentage (an integer clamp bound handed to `Float.round/2`, #1900)
  surfaced as `:probe_failed` and read as a multi-day provider outage, because
  nothing in the projection or the logs could tell the operator that the
  provider had answered perfectly and *we* had crashed.

  So a raise reports `:probe_crashed` and is logged with its exception and
  stacktrace. The dashboard and Stream Deck may still render both as unhealthy
  — the value is that the reason, the snapshot's `health.failure`, and the log
  line all name the real failure.
  """

  require Logger

  @reason :probe_crashed

  @doc """
  Log a contained probe crash and return `reason/0`.

  `kind` is `:error` for a rescued exception or the throw/exit kind for a
  caught one. Logging is itself best-effort: a formatter that blows up must
  not defeat the containment it is reporting on.
  """
  @spec log(atom(), atom(), term(), Exception.stacktrace()) :: :probe_crashed
  def log(provider, kind, error, stacktrace) do
    Logger.error(
      "provider meter probe crashed provider=#{inspect(provider)} reason=#{inspect(@reason)}\n" <>
        Exception.format(kind, error, stacktrace)
    )

    @reason
  rescue
    _error -> @reason
  catch
    _kind, _reason -> @reason
  end
end
