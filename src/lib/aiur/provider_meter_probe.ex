defmodule Aiur.ProviderMeterProbe do
  @moduledoc """
  Observes provider usage without an agent ticket.

  The two providers are observed differently, because they expose their
  standing differently. Both were verified against the real thing.

  **Codex** pushes `account/rateLimits/updated` on app-server connect, with a
  consumed percentage. So its probe opens a session, lets the existing
  notification handler ingest what arrives, and closes it — no turn, no tokens
  spent. Nothing is ingested here directly, so there is no second ingest path
  to keep correct.

  **Claude** is read over HTTP instead. Its `rate_limit_event` carries a
  standing and a reset time but never a consumed fraction, so no session — with
  or without a turn — can produce a percentage. The account usage endpoint can,
  and it is what the Claude Code TUI's own `/usage` reads. Going straight to it
  needs no agent, no turn, and no session-scoped binding, which is what lets
  Claude's meter work on an idle daemon. See `Aiur.Claude.UsageApi`.

  A probe that cannot observe is not an error: the retained observation keeps
  displaying with its true age, and the outcome names why.
  """

  alias Aiur.Claude.UsageApi
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.Config
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot

  # How long to hold a probe session open waiting for the provider to push its
  # rate-limit notification. Generous enough for a cold app-server start,
  # bounded so a hung provider cannot pin a session open.
  @observation_window_ms 8_000
  @probe_identifier "usage-probe"
  @backend :app_server

  @type target :: :all | :codex | :claude
  @type outcome :: %{provider: :codex | :claude, observed?: boolean(), reason: atom() | nil}

  @doc """
  Probe one provider or all of them. Never raises; returns a per-provider outcome.
  """
  @spec observe(target(), keyword()) :: [outcome()]
  def observe(target \\ :all, opts \\ [])

  def observe(:all, opts), do: Enum.map([:codex, :claude], &observe_provider(&1, opts))
  def observe(provider, opts) when provider in [:codex, :claude], do: [observe_provider(provider, opts)]

  defp observe_provider(:claude, opts), do: observe_claude(opts)

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

  # Claude is observed over HTTP, not by opening a session. Its rate-limit
  # event carries no consumed fraction, so a session could only ever report a
  # standing; the account usage endpoint reports the percentage and needs no
  # agent, no turn, and no session-scoped binding.
  defp observe_claude(opts) do
    case Keyword.get(opts, :usage_api, UsageApi).fetch(usage_api_opts(opts)) do
      {:ok, reading} ->
        publish_claude_reading(reading, opts)
        outcome(:claude, true, nil)

      {:error, reason} ->
        outcome(:claude, false, reason)
    end
  rescue
    _error -> outcome(:claude, false, :probe_failed)
  catch
    _kind, _reason -> outcome(:claude, false, :probe_failed)
  end

  # Published on the same fan-out the store broadcasts on, so the projection
  # retains it exactly like a session-observed reading. The account generation
  # is nil because none was involved — this observation is account-wide, not
  # bound to a session.
  defp publish_claude_reading(reading, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    Events.broadcast(%ProviderMeterSnapshot{
      provider: :claude,
      backend: @backend,
      provider_account_generation: nil,
      observed_at: observed_at,
      ingested_at: observed_at,
      auth_mode: :subscription,
      source: :claude_usage_api,
      update_kind: :snapshot,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: nil},
      windows: %{
        reading.window => %{
          limit_id: reading.window,
          kind: :rate_limit,
          name: :primary,
          used_percent: reading.used_percent,
          resets_at: reading.resets_at,
          source: :claude_usage_api,
          observed_at: observed_at,
          coverage: :supported
        }
      }
    })
  end

  defp usage_api_opts(opts), do: Keyword.take(opts, [:credentials_path, :request_fun, :now_ms])

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
      observed_at(provider, opts) != before ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(200)
        poll_until(provider, before, deadline, opts)
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

  defp outcome(provider, observed?, reason), do: %{provider: provider, observed?: observed?, reason: reason}

  defp probe_reason(reason) when is_atom(reason), do: reason
  defp probe_reason(_reason), do: :probe_failed
end
