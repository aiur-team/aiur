defmodule Aiur.ProviderMeterProbe do
  @moduledoc """
  Observes provider usage without an agent ticket.

  Limits are not fetchable from either CLI — neither `claude` nor `codex`
  exposes a usage subcommand, and `claude -p "/usage"` reports that
  invocation's own cost rather than the account's. Limits arrive only as
  app-server notifications (`account/rateLimits/updated` for Codex,
  `rate_limit/update` for Claude), which the existing session machinery
  already routes into `Aiur.ProviderMeters`.

  So a probe is a *session*, not a request: open an app-server session, let its
  notification handler ingest whatever the provider pushes, and close it.
  Nothing is ingested here directly — the probe only creates the conditions for
  an observation, so there is no second ingest path to keep correct.

  Sessions are closed as soon as the observation window elapses. A probe that
  cannot open a session, or opens one that pushes nothing, is not an error: the
  retained observation keeps displaying with its true age.

  ## What each provider actually pushes

  Verified against the real app-servers, not assumed:

  - **Codex** pushes its rate limits on session connect, so a probe observes
    without starting a turn and without spending tokens.
  - **Claude** pushes nothing on connect — a 45s window observed no
    notification. It appears to emit `rate_limit/update` only once a turn runs,
    so Claude's meters populate when agents work rather than at boot.

  Claude is probed anyway: the session opens cleanly, the cost is one
  short-lived process, and it starts reporting the moment that behaviour
  changes. What is deliberately *not* done is starting a turn to force the
  notification — that would spend the very quota the meter reports, on every
  boot and every refresh.
  """

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Config
  alias Aiur.ProviderMeterProjection

  # How long to hold a probe session open waiting for the provider to push its
  # rate-limit notification. Generous enough for a cold app-server start,
  # bounded so a hung provider cannot pin a session open.
  @observation_window_ms 8_000
  @probe_identifier "usage-probe"

  @type target :: :all | :codex | :claude
  @type outcome :: %{provider: :codex | :claude, observed?: boolean(), reason: atom() | nil}

  @doc """
  Probe one provider or all of them. Never raises; returns a per-provider outcome.
  """
  @spec observe(target(), keyword()) :: [outcome()]
  def observe(target \\ :all, opts \\ [])

  def observe(:all, opts), do: Enum.map([:codex, :claude], &observe_provider(&1, opts))
  def observe(provider, opts) when provider in [:codex, :claude], do: [observe_provider(provider, opts)]

  defp observe_provider(provider, opts) do
    before = observed_at(provider, opts)

    case open_probe_session(provider, opts) do
      {:ok, session, close} ->
        wait_for_observation(provider, before, opts)
        safe_close(close, session)
        outcome(provider, observed_at(provider, opts) != before, nil)

      {:error, reason} ->
        outcome(provider, false, reason)
    end
  end

  # Codex is probed through the same app-server client the agents use, so the
  # notification path and its account-generation binding are the proven ones.
  defp open_probe_session(:codex, opts) do
    with {:ok, workspace} <- probe_workspace(opts),
         agent = codex_agent(opts),
         {:ok, session} <- agent.start_session(workspace, identifier: @probe_identifier) do
      {:ok, session, &agent.stop_session/1}
    else
      {:error, reason} -> {:error, probe_reason(reason)}
      other -> {:error, probe_reason(other)}
    end
  rescue
    error -> {:error, probe_reason(error)}
  catch
    _kind, reason -> {:error, probe_reason(reason)}
  end

  defp open_probe_session(:claude, opts) do
    with {:ok, workspace} <- probe_workspace(opts),
         agent = claude_agent(opts),
         {:ok, session} <- agent.start_session(workspace, identifier: @probe_identifier) do
      {:ok, session, &agent.stop_session/1}
    else
      {:error, reason} -> {:error, probe_reason(reason)}
      other -> {:error, probe_reason(other)}
    end
  rescue
    error -> {:error, probe_reason(error)}
  catch
    _kind, reason -> {:error, probe_reason(reason)}
  end

  # The app-server refuses a cwd outside the configured workspace root, so the
  # probe gets its own directory under that root rather than borrowing an
  # agent's workspace (which could be mid-checkout) or the daemon's cwd.
  defp probe_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) ->
        {:ok, workspace}

      _unset ->
        workspace = Path.join(Config.workspace_root(), @probe_identifier)

        case File.mkdir_p(workspace) do
          :ok -> {:ok, workspace}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _error -> {:error, :no_workspace_root}
  catch
    _kind, _reason -> {:error, :no_workspace_root}
  end

  defp wait_for_observation(provider, before, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :observation_window_ms, @observation_window_ms)
    poll_until(provider, before, deadline, opts)
  end

  defp poll_until(provider, before, deadline, opts) do
    cond do
      observed_at(provider, opts) != before -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(200) && poll_until(provider, before, deadline, opts)
    end
  end

  defp observed_at(provider, opts) do
    opts
    |> Keyword.get(:projection, ProviderMeterProjection)
    |> ProviderMeterProjection.provider_view(provider)
    |> Map.get(:observed_at)
  end

  defp safe_close(close, session) do
    close.(session)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp codex_agent(opts), do: Keyword.get(opts, :codex_agent, CodexAgent)
  defp claude_agent(opts), do: Keyword.get(opts, :claude_agent, ClaudeAgent)

  defp outcome(provider, observed?, reason), do: %{provider: provider, observed?: observed?, reason: reason}

  defp probe_reason(reason) when is_atom(reason), do: reason
  defp probe_reason(_reason), do: :probe_failed
end
