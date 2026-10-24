defmodule Aiur.Orchestrator.HostedModeCheck do
  @moduledoc "Fail-closed hosted-execution validation shared by boot and config reloads."

  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.AgentEnvironment.Contributor
  alias Aiur.Config.AgentSettings
  alias Aiur.Config.RoutingValue
  alias Aiur.Config.Schema
  alias Aiur.Harness.Capabilities

  @impl true
  def applies?(_settings), do: true

  @impl true
  def check(settings), do: validate(settings)

  @doc "Validate the immutable instance mode and every hosted execution boundary."
  @spec validate(Schema.t(), keyword()) :: :ok | {:error, term()}
  def validate(settings, opts \\ []) do
    mode = settings.instance.mode
    booted_mode = input(opts, :booted_mode, fn -> Application.get_env(:aiur, :booted_instance_mode) end)

    cond do
      is_binary(booted_mode) and booted_mode != mode ->
        {:error, {:instance_mode_change_requires_restart, booted_mode, mode}}

      mode == "hosted" ->
        validate_hosted(settings, opts)

      true ->
        :ok
    end
  end

  @doc "Validate ticket-level settings that can opt a dispatch into Remote Control."
  @spec validate_dispatch(Schema.t(), Aiur.Issue.t(), keyword()) :: :ok | {:error, term()}
  def validate_dispatch(settings, issue, opts \\ [])

  def validate_dispatch(%{instance: %{mode: "hosted"}} = settings, issue, opts) do
    with :ok <- validate(settings, opts) do
      remote_override? = input(opts, :remote_override?, fn -> Aiur.CodingAgent.remote_control_forced?(issue) end)
      dispatch_backend = input(opts, :dispatch_backend, fn -> Aiur.CodingAgent.backend_for(issue) end)
      entries = input(opts, :registry_entries, &Aiur.CodingAgent.backends/0)

      violations =
        if(remote_override?, do: ["model:remote overrides are not allowed"], else: []) ++
          transport_violations(dispatch_backend, Map.get(entries, dispatch_backend, %{}))

      if violations == [], do: :ok, else: {:error, {:unsafe_hosted_mode, violations}}
    end
  end

  def validate_dispatch(_settings, _issue, _opts), do: :ok

  @doc false
  @spec validate_configured_dispatch(Aiur.Issue.t(), keyword()) :: :ok | {:error, term()}
  def validate_configured_dispatch(issue, opts) do
    opts |> Keyword.get_lazy(:hosted_mode_settings, &Aiur.Config.settings!/0) |> validate_dispatch(issue, opts)
  end

  @doc "Reject the test harness remote-bypass flag in hosted mode."
  @spec validate_allow_remote(String.t()) :: :ok | {:error, String.t()}
  def validate_allow_remote("hosted"),
    do: {:error, "--allow-remote is not allowed when instance.mode is hosted"}

  def validate_allow_remote(_mode), do: :ok

  defp validate_hosted(settings, opts) do
    violations =
      execution_surface_violations(opts) ++
        configuration_violations(settings) ++
        backend_violations(settings, opts) ++
        contributor_violations(opts)

    if violations == [], do: :ok, else: {:error, {:unsafe_hosted_mode, violations}}
  end

  defp execution_surface_violations(opts) do
    interactive_cli? =
      input(opts, :interactive_cli?, fn ->
        Application.get_env(:aiur, :interactive_cli, false) and
          not Application.get_env(:aiur, :headless, false)
      end)

    if interactive_cli?, do: ["local tmux panes are not allowed"], else: []
  end

  defp configuration_violations(settings) do
    codex_configuration_violations(settings) ++ remote_control_violations(settings)
  end

  defp codex_configuration_violations(settings) do
    approval_policy = settings.agent.codex.approval_policy
    thread_sandbox = settings.agent.codex.thread_sandbox

    approval_violations =
      if approval_policy in ["untrusted", "on-failure", "on-request", "granular"] do
        []
      else
        ["agent.codex.approval_policy must require approval, got #{inspect(approval_policy)}"]
      end

    sandbox_violations =
      if thread_sandbox in ["workspace-write", "read-only"] do
        []
      else
        ["agent.codex.thread_sandbox must be bounded, got #{inspect(thread_sandbox)}"]
      end

    approval_violations ++ sandbox_violations
  end

  defp remote_control_violations(settings) do
    global =
      if settings.agent.remote_control do
        ["agent.remote_control is not allowed"]
      else
        []
      end

    routes =
      settings.agent.routing_candidates
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(is_binary(&1) and RoutingValue.routing_remote_flag?(&1)))
      |> Enum.sort()
      |> Enum.map(&"agent.routing route #{inspect(&1)} enables +remote")

    global ++ routes
  end

  defp backend_violations(settings, opts) do
    entries = input(opts, :registry_entries, &Aiur.CodingAgent.backends/0)

    dispatchable =
      input(opts, :dispatchable_backends, fn ->
        settings
        |> AgentSettings.agent_backend_configs()
        |> Aiur.CodingAgent.dispatchable_backends()
      end)

    dispatchable
    |> Enum.sort()
    |> Enum.flat_map(fn backend ->
      entry = Map.get(entries, backend, %{})
      facts = Capabilities.hosted_security_for_entry(entry)

      permission_violations(backend, facts.permission_boundary, settings) ++
        network_violations(backend, facts.network_boundary, settings) ++
        credential_violations(backend, facts.credential_boundary) ++
        transport_violations(backend, entry)
    end)
  end

  defp permission_violations(_backend, :enforced, _settings), do: []

  defp permission_violations(backend, :codex_sandbox, settings) do
    case Schema.resolve_turn_sandbox_policy(settings) |> field("type") do
      type when type in ["workspaceWrite", "readOnly"] -> []
      type -> ["backend #{backend} has unsafe Codex sandbox type #{inspect(type)}"]
    end
  end

  defp permission_violations(backend, :claude_permission_mode, settings) do
    case settings.agent.claude.permission_mode do
      "bypassPermissions" -> ["backend #{backend} uses agent.claude.permission_mode=bypassPermissions"]
      mode when mode in ["default", "acceptEdits"] -> []
      mode -> ["backend #{backend} has unknown Claude permission mode #{inspect(mode)}"]
    end
  end

  defp permission_violations(backend, boundary, _settings),
    do: ["backend #{backend} has no trusted permission boundary (#{inspect(boundary)})"]

  defp network_violations(_backend, :denied, _settings), do: []

  defp network_violations(backend, :codex_sandbox, settings) do
    case Schema.resolve_turn_sandbox_policy(settings) |> field("networkAccess") do
      false -> []
      value -> ["backend #{backend} requires agent.codex.turn_sandbox_policy.networkAccess=false, got #{inspect(value)}"]
    end
  end

  defp network_violations(backend, boundary, _settings),
    do: ["backend #{backend} does not deny agent network access (#{inspect(boundary)})"]

  defp credential_violations(_backend, :daemon), do: []

  defp credential_violations(backend, boundary),
    do: ["backend #{backend} does not keep credentials daemon-side (#{inspect(boundary)})"]

  defp transport_violations(backend, entry) do
    if get_in(entry, [:delivery, :transport]) == :tmux_pane do
      ["backend #{backend} uses a local tmux REPL transport"]
    else
      []
    end
  end

  defp contributor_violations(opts) do
    opts
    |> input(:contributor_boundaries, &Contributor.hosted_credential_boundaries/0)
    |> Enum.sort_by(fn {contributor, _boundary} -> inspect(contributor) end)
    |> Enum.flat_map(fn
      {_contributor, :daemon} -> []
      {contributor, boundary} -> ["agent environment contributor #{inspect(contributor)} does not keep credentials daemon-side (#{inspect(boundary)})"]
    end)
  end

  defp field(map, "type"), do: Map.get(map, "type", Map.get(map, :type))
  defp field(map, "networkAccess"), do: Map.get(map, "networkAccess", Map.get(map, :networkAccess))

  defp input(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, fun} when is_function(fun, 0) -> fun.()
      {:ok, value} -> value
      :error -> default.()
    end
  end
end
