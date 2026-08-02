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

  **Kimi** reports throughput headroom on inference response headers, so an
  idle probe cannot invent a value. **DeepSeek** exposes prepaid balance and
  Aiur combines it with local in-flight count. **OpenRouter** exposes purchased
  credits and usage to a management key; missing management credentials leave
  the reading unavailable.

  A probe that cannot observe is not an error: the retained observation keeps
  displaying with its true age, and the outcome names why.
  """

  alias Aiur.Claude.UsageApi
  alias Aiur.{CodingAgent, Config}
  alias Aiur.OpenAICompat.Concurrency
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot
  alias Aiur.Workspace

  # How long to hold a probe session open waiting for the provider to push its
  # rate-limit notification. Generous enough for a cold app-server start,
  # bounded so a hung provider cannot pin a session open.
  @observation_window_ms 8_000
  @probe_identifier "usage-probe"
  @backend :app_server
  @openai_compat_backend :openai_compat
  @openai_compat_source_versions %{deepseek: 144_003, openrouter: 144_004}
  @deepseek_concurrency_limit 2_500
  @batch_timeout_ms 35_000

  @type target :: :all | atom()
  @type outcome :: %{provider: atom(), observed?: boolean(), reason: atom() | nil}

  @doc """
  Probe one provider or all of them. Never raises; returns a per-provider outcome.
  """
  @spec observe(target(), keyword()) :: [outcome()]
  def observe(target \\ :all, opts \\ [])

  def observe(:all, opts) do
    providers = CodingAgent.provider_families()
    opts = Keyword.put(opts, :dispatchable_provider_set, dispatchable_provider_set(opts))

    results =
      Task.async_stream(providers, &observe_provider(&1, opts),
        max_concurrency: max(length(providers), 1),
        ordered: true,
        timeout: Keyword.get(opts, :batch_timeout_ms, @batch_timeout_ms),
        on_timeout: :kill_task
      )

    providers
    |> Enum.zip(results)
    |> Enum.map(fn
      {_provider, {:ok, result}} -> result
      {provider, {:exit, _reason}} -> outcome(provider, false, :probe_failed)
    end)
  end

  def observe(provider, opts) when is_atom(provider) do
    opts = Keyword.put(opts, :dispatchable_provider_set, dispatchable_provider_set(opts))
    [observe_provider(provider, opts)]
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

  defp provider_probe_enabled?(provider, opts) do
    provider |> Atom.to_string() |> then(&MapSet.member?(Keyword.fetch!(opts, :dispatchable_provider_set), &1))
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

    case open_probe_session(backend, opts) do
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
  defp open_probe_session(backend, opts) do
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
    error -> {:error, probe_reason(error)}
  catch
    _kind, reason -> {:error, probe_reason(reason)}
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
    _error -> outcome(provider, false, :probe_failed)
  catch
    _kind, _reason -> outcome(provider, false, :probe_failed)
  end

  @doc false
  @spec probe_openai_compat(atom(), String.t(), keyword()) :: outcome()
  def probe_openai_compat(:kimi, _backend, _opts),
    do: outcome(:kimi, false, :session_observation_only)

  def probe_openai_compat(provider, backend, opts) when provider in [:deepseek, :openrouter] do
    with {:ok, config} <- openai_compat_config(backend),
         {:ok, env_name} <- meter_key_env(provider, config),
         {:ok, api_key} <- fetch_api_key(env_name, opts),
         request = balance_request(provider, config, api_key),
         {:ok, response} <- openai_compat_request(request, opts),
         :ok <- openai_compat_status(response),
         {:ok, windows} <- balance_windows(provider, Map.get(response, :body), opts) do
      publish_openai_compat_reading(provider, windows, opts)
      outcome(provider, true, nil)
    else
      {:error, reason} -> outcome(provider, false, reason)
    end
  rescue
    _error -> outcome(provider, false, :probe_failed)
  catch
    _kind, _reason -> outcome(provider, false, :probe_failed)
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
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: nil},
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

  defp publish_openai_compat_reading(provider, windows, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    Events.broadcast(%ProviderMeterSnapshot{
      provider: provider,
      backend: @openai_compat_backend,
      provider_account_generation: nil,
      observed_at: observed_at,
      ingested_at: observed_at,
      auth_mode: :api_key,
      source: meter_source(provider),
      source_version: Map.fetch!(@openai_compat_source_versions, provider),
      update_kind: :patch,
      freshness: :fresh,
      health: %{
        state: :healthy,
        failure: nil,
        last_observed_at: observed_at,
        last_source_version: Map.fetch!(@openai_compat_source_versions, provider)
      },
      windows: Map.new(windows, &{&1.limit_id, Map.delete(&1, :limit_id)})
    })
  end

  defp openai_compat_config(backend) do
    case get_in(CodingAgent.backends(), [backend, :openai_compat]) do
      %{} = config -> {:ok, config}
      _ -> {:error, :unsupported}
    end
  end

  defp meter_key_env(:deepseek, config), do: required_string(config[:api_key_env])
  defp meter_key_env(:openrouter, config), do: required_string(config[:management_api_key_env])

  defp required_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_value), do: {:error, :missing_api_key_configuration}

  defp fetch_api_key(env_name, opts) do
    case Keyword.get(opts, :api_key_fetcher, &System.get_env/1).(env_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_api_key}
    end
  end

  defp balance_request(:deepseek, config, api_key) do
    %{method: :get, url: String.trim_trailing(config.base_url, "/") <> "/user/balance", headers: %{"authorization" => "Bearer #{api_key}"}}
  end

  defp balance_request(:openrouter, config, api_key) do
    %{method: :get, url: String.trim_trailing(config.base_url, "/") <> "/credits", headers: %{"authorization" => "Bearer #{api_key}"}}
  end

  defp openai_compat_request(request, opts) do
    Keyword.get(opts, :openai_compat_request_fun, &default_openai_compat_request/1).(request)
  end

  defp default_openai_compat_request(%{url: url, headers: headers}) do
    case Req.get(url, headers: Map.to_list(headers), receive_timeout: 30_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp openai_compat_status(%{status: status}) when status in 200..299, do: :ok
  defp openai_compat_status(%{status: 401}), do: {:error, :authentication}
  defp openai_compat_status(%{status: 429}), do: {:error, :rate_limited}
  defp openai_compat_status(%{status: _status}), do: {:error, :provider_error}
  defp openai_compat_status(_response), do: {:error, :malformed}

  defp balance_windows(:deepseek, %{"balance_infos" => infos}, opts) when is_list(infos) do
    with %{} = usd <- Enum.find(infos, &(String.upcase(to_string(&1["currency"] || "")) == "USD")),
         {:ok, balance} <- non_negative_number(usd["total_balance"]) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
      in_flight = Keyword.get(opts, :deepseek_in_flight, Concurrency.current("deepseek"))

      {:ok,
       [
         credit_window("prepaid-balance-usd", balance, :deepseek_api, observed_at),
         concurrency_window(in_flight, observed_at)
       ]}
    else
      _ -> {:error, :malformed}
    end
  end

  defp balance_windows(:openrouter, %{"data" => data}, opts) when is_map(data) do
    with {:ok, credits} <- non_negative_number(data["total_credits"]),
         {:ok, usage} <- non_negative_number(data["total_usage"]) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
      {:ok, [credit_window("credits-remaining", max(credits - usage, 0), :openrouter_api, observed_at)]}
    else
      _ -> {:error, :malformed}
    end
  end

  defp balance_windows(_provider, _body, _opts), do: {:error, :malformed}

  defp credit_window(id, amount, source, observed_at) do
    %{
      limit_id: id,
      kind: :credit,
      name: :credits,
      credits: %{status: if(amount > 0, do: :available, else: :exhausted), amount: amount},
      remaining: amount,
      source: source,
      observed_at: observed_at,
      expires_at: DateTime.add(observed_at, 300, :second),
      coverage: :supported
    }
  end

  defp concurrency_window(in_flight, observed_at) when is_integer(in_flight) and in_flight >= 0 do
    %{
      limit_id: "local-concurrency",
      kind: :rate_limit,
      name: :concurrency,
      used_percent: in_flight / @deepseek_concurrency_limit * 100,
      used: in_flight,
      limit: @deepseek_concurrency_limit,
      remaining: max(@deepseek_concurrency_limit - in_flight, 0),
      source: :deepseek_api,
      observed_at: observed_at,
      expires_at: DateTime.add(observed_at, 60, :second),
      coverage: :supported
    }
  end

  defp non_negative_number(value) when is_number(value) and value >= 0, do: {:ok, value}

  defp non_negative_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :malformed}
    end
  end

  defp non_negative_number(_value), do: {:error, :malformed}

  defp meter_source(:deepseek), do: :deepseek_api
  defp meter_source(:openrouter), do: :openrouter_api

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

  defp probe_reason(reason) when is_atom(reason), do: reason
  defp probe_reason(_reason), do: :probe_failed
end
