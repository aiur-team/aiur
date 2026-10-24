defmodule Aiur.Orchestrator.HostedModeCheck do
  @moduledoc "Fail-closed hosted-execution validation shared by boot and config reloads."

  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.AgentEnvironment.Contributor
  alias Aiur.Config.AgentSettings
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
    booted_mode = Keyword.get(opts, :booted_mode, Application.get_env(:aiur, :booted_instance_mode))

    cond do
      is_binary(booted_mode) and booted_mode != mode ->
        {:error, {:instance_mode_change_requires_restart, booted_mode, mode}}

      mode == "hosted" ->
        validate_hosted(settings, opts)

      true ->
        :ok
    end
  end

  defp validate_hosted(settings, opts) do
    violations = backend_violations(settings, opts) ++ contributor_violations(opts)
    if violations == [], do: :ok, else: {:error, {:unsafe_hosted_mode, violations}}
  end

  defp backend_violations(settings, opts) do
    entries = Keyword.get_lazy(opts, :registry_entries, &Aiur.CodingAgent.backends/0)

    dispatchable =
      Keyword.get_lazy(opts, :dispatchable_backends, fn ->
        settings
        |> AgentSettings.agent_backend_configs()
        |> Aiur.CodingAgent.dispatchable_backends()
      end)

    dispatchable
    |> Enum.sort()
    |> Enum.flat_map(fn backend ->
      facts = entries |> Map.get(backend, %{}) |> Capabilities.hosted_security_for_entry()

      permission_violations(backend, facts.permission_boundary, settings) ++
        network_violations(backend, facts.network_boundary, settings) ++
        credential_violations(backend, facts.credential_boundary)
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

  defp contributor_violations(opts) do
    opts
    |> Keyword.get_lazy(:contributor_boundaries, &Contributor.hosted_credential_boundaries/0)
    |> Enum.sort_by(fn {contributor, _boundary} -> inspect(contributor) end)
    |> Enum.flat_map(fn
      {_contributor, :daemon} -> []
      {contributor, boundary} -> ["agent environment contributor #{inspect(contributor)} does not keep credentials daemon-side (#{inspect(boundary)})"]
    end)
  end

  defp field(map, "type"), do: Map.get(map, "type", Map.get(map, :type))
  defp field(map, "networkAccess"), do: Map.get(map, "networkAccess", Map.get(map, :networkAccess))
end
