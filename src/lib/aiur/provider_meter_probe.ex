defmodule Aiur.ProviderMeterProbe do
  @moduledoc """
  Observes provider usage without an agent ticket.

  Providers are observed according to the registry-declared probe for their
  family, because each exposes a different honest standing.

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

  OpenAI-compatible providers delegate their provider-specific balance and
  credit probes to `Aiur.OpenAICompat.ProviderMeterProbe`.

  A probe that cannot observe is not an error: the retained observation keeps
  displaying with its true age, and the outcome names why.
  """

  alias Aiur.Claude.UsageApi
  alias Aiur.{CodingAgent, Config}
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.{Events, ProbeCrash}
  alias Aiur.ProviderMeterSnapshot
  alias Aiur.Workspace

  # How long to hold a probe session open waiting for the provider to push its
  # rate-limit notification. Generous enough for a cold app-server start,
  # bounded so a hung provider cannot pin a session open.
  @observation_window_ms 8_000
  @probe_identifier "usage-probe"
  @backend :app_server
  @batch_timeout_ms 35_000

  @type target :: :all | atom()
  @type outcome :: %{provider: atom(), observed?: boolean(), reason: atom() | nil}

  @doc """
  Probe one provider or all of them. Never raises; returns a per-provider outcome.
  """
  @spec observe(target(), keyword()) :: [outcome()]
  def observe(target \\ :all, opts \\ [])

  def observe(:all, opts) do
    opts = Keyword.put_new(opts, :attempted_at, Keyword.get(opts, :observed_at, DateTime.utc_now()))
    providers = CodingAgent.provider_families()
    opts = Keyword.put(opts, :dispatchable_provider_set, dispatchable_provider_set(opts))

    results =
      Task.async_stream(providers, &observe_provider(&1, opts),
        max_concurrency: max(length(providers), 1),
        ordered: true,
        timeout: Keyword.get(opts, :batch_timeout_ms, @batch_timeout_ms),
        on_timeout: :kill_task
      )

    outcomes =
      providers
      |> Enum.zip(results)
      |> Enum.map(fn
        {_provider, {:ok, result}} -> result
        {provider, {:exit, reason}} -> outcome(provider, false, task_exit_reason(provider, reason))
      end)

    Enum.map(outcomes, &record_probe_result(&1, opts))
  end

  def observe(provider, opts) when is_atom(provider) do
    opts = Keyword.put_new(opts, :attempted_at, Keyword.get(opts, :observed_at, DateTime.utc_now()))
    opts = Keyword.put(opts, :dispatchable_provider_set, dispatchable_provider_set(opts))
    [observe_provider(provider, opts) |> record_probe_result(opts)]
  end

  defp observe_provider(provider, opts) do
    if provider_probe_enabled?(provider, opts) do
      case CodingAgent.provider_meter_probe(provider) do
        {backend, probe} when is_function(probe, 3) -> probe.(provider, backend, opts)
        nil -> outcome(provider, false, :unsupported)
      end
    else
      outcome(provider, false, :disabled)
    end
  end

  # A provider is observed when it can actually be observed, which is not the
  # same as being dispatchable. A balance or credits read is a read-only HTTP
  # GET: it provisions nothing, so a backend the operator has not yet enabled
  # for dispatch must still render its meter — seeing the balance is exactly
  # what a disabled backend's operator needs to decide whether to enable it.
  # Probing stays bounded to providers that are either dispatchable or carry a
  # configured API key, so a provider with no credentials is never touched.
  defp provider_probe_enabled?(provider, opts) do
    dispatchable?(provider, opts) or keyed?(provider, opts)
  end

  defp dispatchable?(provider, opts) do
    provider |> Atom.to_string() |> then(&MapSet.member?(Keyword.fetch!(opts, :dispatchable_provider_set), &1))
  end

  # OpenAI-compatible providers resolve their credential env from the registry
  # (`api_key_env` / `management_api_key_env`). A provider with either env set
  # can be observed even while it is not dispatchable.
  defp keyed?(provider, opts) do
    with %{} = compat <- get_in(CodingAgent.backends(), [Atom.to_string(provider), :openai_compat]),
         env when is_binary(env) and env != "" <-
           Map.get(compat, :management_api_key_env) || Map.get(compat, :api_key_env) do
      case Keyword.get(opts, :api_key_fetcher, &System.get_env/1).(env) do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp dispatchable_provider_set(opts) do
    opts
    |> Keyword.get_lazy(:backend_configs, &Config.agent_backend_configs/0)
    |> CodingAgent.dispatchable_backends()
    |> MapSet.new()
  rescue
    _error -> MapSet.new(CodingAgent.dispatchable_backends())
  catch
    _kind, _reason -> MapSet.new(CodingAgent.dispatchable_backends())
  end

  @doc false
  @spec probe_session(atom(), String.t(), keyword()) :: outcome()
  def probe_session(provider, backend, opts) do
    before = observed_at(provider, opts)

    case open_probe_session(provider, backend, opts) do
      {:ok, session, close} ->
        # The poll result is authoritative: once the window has seen the
        # observation land, a later projection read that times out or finds the
        # process momentarily gone must not downgrade it back to "not observed".
        # The re-read only covers an observation that arrived during the close.
        observed? = wait_for_observation(provider, before, opts) == :ok
        safe_close(close, session)
        outcome(provider, observed? or observed_at(provider, opts) != before, nil)

      {:error, reason} ->
        outcome(provider, false, reason)
    end
  end

  # Codex is probed through the same app-server client the agents use, so the
  # notification path and its account-generation binding are the proven ones.
  defp open_probe_session(provider, backend, opts) do
    with {:ok, workspace} <- probe_workspace(opts),
         agent = probe_agent(backend, opts),
         true <- is_atom(agent),
         {:ok, session} <- agent.start_session(workspace, identifier: @probe_identifier) do
      {:ok, session, &agent.stop_session/1}
    else
      {:error, reason} -> {:error, probe_reason(reason)}
      other -> {:error, probe_reason(other)}
    end
  rescue
    # A refused or failed session start arrives above as `{:error, reason}` and
    # keeps its own reason; a raise here is our bug rather than the provider's
    # silence.
    error -> {:error, ProbeCrash.log(provider, :error, error, __STACKTRACE__)}
  catch
    :throw, value ->
      {:error, ProbeCrash.log(provider, :throw, value, __STACKTRACE__)}

    # An *exit* is the opposite case and must not be relabelled a crash: the
    # dominant one here is the app-server being slow or absent, which arrives
    # as a `GenServer.call` exit. That is precisely "the provider did not
    # answer", so it keeps `probe_reason/1` — otherwise a down app-server would
    # log a crash with a stacktrace on every probe cycle, which is the exact
    # miscategorisation this split exists to prevent, running the other way.
    :exit, reason ->
      {:error, probe_reason(reason)}
  end

  # Claude is observed over HTTP, not by opening a session. Its rate-limit
  # event carries no consumed fraction, so a session could only ever report a
  # standing; the account usage endpoint reports the percentage and needs no
  # agent, no turn, and no session-scoped binding.
  @doc false
  @spec probe_usage_api(atom(), String.t(), keyword()) :: outcome()
  def probe_usage_api(provider, _backend, opts) do
    case Keyword.get(opts, :usage_api, UsageApi).fetch(usage_api_opts(opts)) do
      {:ok, reading} ->
        publish_usage_api_reading(provider, reading, opts)
        outcome(provider, true, nil)

      {:error, reason} ->
        outcome(provider, false, reason)
    end
  rescue
    error -> outcome(provider, false, ProbeCrash.log(provider, :error, error, __STACKTRACE__))
  catch
    kind, reason -> outcome(provider, false, ProbeCrash.log(provider, kind, reason, __STACKTRACE__))
  end

  # Published on the same fan-out the store broadcasts on, so the projection
  # retains it exactly like a session-observed reading. The account generation
  # is nil because none was involved — this observation is account-wide, not
  # bound to a session.
  defp publish_usage_api_reading(provider, reading, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    Events.broadcast(%ProviderMeterSnapshot{
      provider: provider,
      backend: @backend,
      provider_account_generation: nil,
      observed_at: observed_at,
      ingested_at: observed_at,
      auth_mode: :subscription,
      source: :usage_api,
      update_kind: :snapshot,
      freshness: :fresh,
      health: %{
        state: :healthy,
        failure: nil,
        last_observed_at: observed_at,
        last_source_version: nil,
        last_attempt_at: nil,
        consecutive_failures: 0
      },
      windows: %{
        reading.window => %{
          limit_id: reading.window,
          kind: :rate_limit,
          name: :primary,
          used_percent: reading.used_percent,
          resets_at: reading.resets_at,
          source: :usage_api,
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
  #
  # The directory is placed in the same owner/repo-namespaced tree that
  # `Workspace.create_for_issue/1` uses for real tickets — not at the bare root
  # of the workspaces tree — and is created on demand here. A bare-root
  # `<workspace_root>/usage-probe` is owned by no machinery: nothing creates it,
  # and the app-server then fails to `cd` into a directory that never existed
  # (#1406). Folding it into the owner-scoped layout makes it created and located
  # exactly like any other workspace.
  defp probe_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) ->
        {:ok, workspace}

      _unset ->
        workspace = Workspace.workspace_path_under(Config.workspace_root(), @probe_identifier)

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

  defp probe_agent(backend, opts), do: Keyword.get(opts, :probe_agent, CodingAgent.adapter(backend))

  defp outcome(provider, observed?, reason), do: %{provider: provider, observed?: observed?, reason: reason}

  defp record_probe_result(result, opts) do
    attempted_at = Keyword.get(opts, :attempted_at, Keyword.get(opts, :observed_at, DateTime.utc_now()))

    _ = ProviderMeterProjection.record_probe_result(Keyword.get(opts, :projection, ProviderMeterProjection), result, attempted_at)
    result
  rescue
    _error -> result
  catch
    _kind, _reason -> result
  end

  # An exit out of the probe task is not automatically our crash. The batch's
  # `on_timeout: :kill_task` reports a provider that ran past the budget as
  # `:timeout`, a daemon stop arrives as `:shutdown`/`:killed`, and a probe
  # reaching a process that is gone exits its `GenServer.call` — none of which
  # is "we raised on an answer we received". Only an exit `probe_reason/1`
  # cannot name is a crash. Its stacktrace lives inside `reason` (an escaped
  # raise exits as `{exception, stacktrace}`), which `Exception.format/3`
  # renders, so the empty outer stacktrace loses nothing.
  defp task_exit_reason(provider, reason) do
    case probe_reason(reason) do
      :probe_failed -> ProbeCrash.log(provider, :exit, reason, [])
      named -> named
    end
  end

  # `is_atom/1` is true of `false`, and the `is_atom(agent)` check in
  # `open_probe_session/3` fails with exactly that — without this clause the
  # failure reason became the atom `false` and the card rendered "false".
  defp probe_reason(false), do: :unsupported
  defp probe_reason(reason) when is_atom(reason), do: reason

  # The two exit shapes a `GenServer.call` into an absent or overloaded
  # app-server produces. Both mean the provider never answered, and naming them
  # is what lets an operator tell "the app-server is down" from "it answered
  # and we mishandled it".
  defp probe_reason({:timeout, {GenServer, :call, _args}}), do: :timeout
  defp probe_reason({:noproc, {GenServer, :call, _args}}), do: :transport
  defp probe_reason(_reason), do: :probe_failed
end
