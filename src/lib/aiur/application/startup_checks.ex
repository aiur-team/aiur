defmodule Aiur.Application.StartupChecks do
  @moduledoc """
  Boot-time validation and logging that runs in `Aiur.Application.start/2`
  before the supervision tree is built.
  """

  require Logger

  alias Aiur.CodingAgent.RouteCredentials
  alias Aiur.Config, as: AiurConfig
  alias Aiur.Config.RoutingValue

  @doc false
  @spec maybe_validate_environment() :: :ok
  def maybe_validate_environment do
    if Application.get_env(:aiur, :env) == :test do
      :ok
    else
      settings = Aiur.Config.settings_uncached()

      validate_secrets!(settings, System.get_env())

      Aiur.Env.validate_startup!(System.get_env(), require_github_credential: github_tracker?(settings))
      Aiur.Env.warn_disabled_integrations()
      Aiur.Env.warn_precedence_conflicts()
    end
  end

  @doc "Validates the secrets required by the active hosted configuration."
  @spec validate_secrets(term(), map()) :: :ok | {:error, [String.t()]}
  def validate_secrets({:ok, settings}, env), do: validate_secrets(settings, env)

  def validate_secrets(settings, env) when is_map(settings) and is_map(env) do
    if Aiur.Secrets.secrets_from_env?(env) do
      missing =
        []
        |> maybe_missing(github_tracker?(settings), github_secret_names(env), env)
        |> maybe_missing(linear_tracker?(settings), ["LINEAR_API_KEY"], env)
        |> maybe_missing(remote_host?(settings), ["AIUR_DASHBOARD_USERNAME", "AIUR_DASHBOARD_PASSWORD"], env)
        |> maybe_missing(webhooks_enabled?(settings), ["AIUR_GITHUB_WEBHOOK_SECRET"], env)
        |> maybe_missing(non_persistent_state?(env), ["AIUR_SECRET_KEY_BASE"], env)
        |> maybe_missing(true, configured_route_secrets(settings, env), env)
        |> Kernel.++(missing_host_allowlist(settings))
        |> Enum.uniq()

      if missing == [], do: :ok, else: {:error, ["missing required secrets: #{Enum.join(missing, ", ")}"]}
    else
      :ok
    end
  end

  def validate_secrets(_settings, _env), do: :ok

  @doc "Raises one safe error listing every missing hosted secret."
  @spec validate_secrets!(term(), map()) :: :ok
  def validate_secrets!(settings, env) do
    case validate_secrets(settings, env) do
      :ok -> :ok
      {:error, [message]} -> raise ArgumentError, message: message
    end
  end

  @doc "Runs the same hosted secret validation on demand."
  @spec validate_hosted_secrets() :: :ok | {:error, [String.t()]}
  def validate_hosted_secrets do
    if Aiur.Secrets.secrets_from_env?() do
      result = validate_secrets(Aiur.Config.settings_uncached(), System.get_env())
      if result == :ok, do: :ok, else: result
    else
      :ok
    end
  end

  defp maybe_missing(acc, true, names, env), do: acc ++ Enum.reject(names, &present_env?(&1, env))
  defp maybe_missing(acc, _condition, _names, _env), do: acc

  defp present_env?(name, env), do: is_binary(env[name]) and String.trim(env[name]) != ""

  defp github_secret_names(env) do
    if present_env?("GITHUB_APP_ID", env) or present_env?("GITHUB_APP_INSTALLATION_ID", env) or
         present_env?("GITHUB_APP_PRIVATE_KEY", env) or present_env?("GITHUB_APP_PRIVATE_KEY_PATH", env) do
      []
      |> then_if_missing("GITHUB_APP_ID", present_env?("GITHUB_APP_ID", env))
      |> then_if_missing("GITHUB_APP_INSTALLATION_ID", present_env?("GITHUB_APP_INSTALLATION_ID", env))
      |> then_if_missing(
        "GITHUB_APP_PRIVATE_KEY or GITHUB_APP_PRIVATE_KEY_PATH",
        present_env?("GITHUB_APP_PRIVATE_KEY", env) or present_env?("GITHUB_APP_PRIVATE_KEY_PATH", env)
      )
    else
      if present_env?("GITHUB_TOKEN", env) or present_env?("GH_TOKEN", env), do: [], else: ["GITHUB_TOKEN or GH_TOKEN"]
    end
  end

  defp then_if_missing(names, _name, true), do: names
  defp then_if_missing(names, name, false), do: names ++ [name]

  defp linear_tracker?(%{tracker: %{kind: "linear"}}), do: true
  defp linear_tracker?(_), do: false

  defp remote_host?(%{server: %{host: host}}), do: host not in [nil, "127.0.0.1", "localhost", "::1"]
  defp remote_host?(_), do: false

  defp missing_host_allowlist(%{server: %{host: host} = server}) do
    remote? = host not in [nil, "127.0.0.1", "localhost", "::1"]
    allowlist? = List.wrap(Map.get(server, :allowed_hosts)) != [] or present_config?(Map.get(server, :public_url))
    if remote? and not allowlist?, do: ["server.allowed_hosts or server.public_url"], else: []
  end

  defp missing_host_allowlist(_), do: []

  defp present_config?(value), do: is_binary(value) and String.trim(value) != ""

  defp webhooks_enabled?(%{webhooks: %{repos: repos}}), do: is_list(repos) and repos != []
  defp webhooks_enabled?(_), do: false

  defp non_persistent_state?(env), do: not Aiur.Secrets.truthy?(env["AIUR_STATE_PERSISTENT"])

  defp configured_route_secrets(%{agent: %{priority: routes} = agent}, env) when is_list(routes) do
    routes = if routes == [], do: [Map.get(agent, :kind)], else: routes
    backend_configs = Map.get(agent, :backend_configs, %{}) || %{}

    routes
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&missing_route_key(&1, backend_configs, env))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_route_secrets(_, _env), do: []

  defp missing_route_key(route, backend_configs, env) do
    backend = RoutingValue.routing_backend(route)
    custom_env = get_in(backend_configs, [backend, "api_key_env"])

    if is_binary(custom_env) and custom_env != "" do
      if present_env?(custom_env, env), do: nil, else: custom_env
    else
      RouteCredentials.missing_key_env(route, api_key_fetcher: fn name -> env[name] end)
    end
  end

  # The GitHub credential boot requirement only applies when the active tracker
  # is GitHub; a Linear or memory tracker has no GitHub credential to satisfy.
  defp github_tracker?(settings) do
    case settings do
      {:ok, %{tracker: %{kind: kind}}} -> kind == "github"
      %{tracker: %{kind: kind}} -> kind == "github"
      _ -> true
    end
  end

  @doc false
  @spec log_base_branch() :: :ok
  @spec log_base_branch(term()) :: :ok
  def log_base_branch(settings \\ AiurConfig.settings_uncached()) do
    Logger.info("aiur_boot phase=config base_branch=#{inspect(AiurConfig.base_branch(settings))}")
    :ok
  end

  @doc """
  Announces, once per boot, every `agent.priority` route that will be skipped
  because its API key is not set.

  A missing key stops being a hard error at dispatch and becomes a silent
  selection-time skip (#1923) — that is the whole point of writing
  `[claude, "openrouter:anthropic/claude-sonnet-5"]` while holding only the
  OpenRouter key. But a behaviour change from "crashes loudly" to "quietly not
  chosen" must not happen invisibly, so it is stated at boot rather than
  per claim, where it would become noise the operator learns to skip.
  """
  @spec log_route_credentials(term()) :: :ok
  def log_route_credentials(settings \\ AiurConfig.settings_uncached()) do
    settings |> priority_routes() |> RouteCredentials.log_startup_survey()
  end

  # `settings_uncached/0` yields `{:ok, schema}` on success and an error tuple
  # when the config is unreadable. Boot must survive the latter: a startup
  # notice is never worth crashing the node over.
  defp priority_routes({:ok, settings}), do: priority_routes(settings)
  defp priority_routes(%{agent: %{priority: routes}}) when is_list(routes), do: routes
  defp priority_routes(_settings), do: []

  @doc """
  Reject a no-dashboard launch when configured Remote Control sessions would
  lose the HTTP lifecycle-hook endpoint they require.

  The optional inputs keep this check pure in tests; production resolves both
  values from the active workflow config.
  """
  @spec validate_dashboard_compatibility(boolean(), keyword()) :: :ok | {:error, String.t()}
  def validate_dashboard_compatibility(no_dashboard?, opts \\ [])

  def validate_dashboard_compatibility(false, _opts), do: :ok

  def validate_dashboard_compatibility(true, opts) do
    remote_control? = Keyword.get_lazy(opts, :remote_control?, &AiurConfig.agent_remote_control?/0)
    routing = Keyword.get_lazy(opts, :routing, &AiurConfig.agent_routing/0)

    sources =
      []
      |> maybe_add_remote_control_source(remote_control?, "agent.remote_control")
      |> maybe_add_remote_control_source(remote_routing?(routing), "agent.routing +remote")

    case sources do
      [] ->
        :ok

      configured_sources ->
        {:error,
         "--no-dashboard cannot be used with Claude Remote Control configured by " <>
           "#{Enum.join(configured_sources, " and ")}; Remote Control lifecycle hooks require " <>
           "Aiur.HttpServer. Remove --no-dashboard or disable the Remote Control setting."}
    end
  end

  defp remote_routing?(routing) when is_map(routing) do
    Enum.any?(routing, fn {_level, value} -> RoutingValue.routing_remote_flag?(value) end)
  end

  defp remote_routing?(_routing), do: false

  defp maybe_add_remote_control_source(sources, true, source), do: sources ++ [source]
  defp maybe_add_remote_control_source(sources, false, _source), do: sources
end
