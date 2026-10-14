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
      Aiur.Env.validate_startup!(System.get_env(), require_github_credential: github_tracker?(settings))
      Aiur.Env.warn_disabled_integrations()
      Aiur.Env.warn_precedence_conflicts()
    end
  end

  # The GitHub credential boot requirement only applies when the active tracker
  # is GitHub; a Linear or memory tracker has no GitHub credential to satisfy.
  defp github_tracker?(settings) do
    case settings do
      {:ok, %{tracker: %{kind: kind}}} -> kind == "github"
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
