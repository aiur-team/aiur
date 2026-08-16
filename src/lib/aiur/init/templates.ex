defmodule Aiur.Init.Templates do
  @moduledoc """
  One home for all compile-time embedded scaffold templates and config-template fill rendering.
  """

  alias Aiur.Init.Questions

  # Scaffolded prompt_file template. PromptBuilder renders this as the whole
  # turn template (Liquid), so it must reference the issue or the agent gets
  # no task. The `{{REPO}}` placeholder is init-filled (not Liquid); turn-time
  # `{{ issue.* }}` Liquid is preserved for PromptBuilder.
  @prompt_example_path Path.expand("../../../../.aiur/examples/prompt.md.example", __DIR__)
  @external_resource @prompt_example_path
  @prompt_example_template File.read!(@prompt_example_path)
  @repo_placeholder "{{REPO}}"

  @executor_handoff_example_path Path.expand("../../../../.aiur/examples/executor-handoff.md.example", __DIR__)
  @external_resource @executor_handoff_example_path
  @executor_handoff_example_template File.read!(@executor_handoff_example_path)

  @env_content "GITHUB_TOKEN=\n"

  # Embed the annotated example at compile time so the wizard works from a
  # release without a runtime file dependency. aiur dogfoods the `.aiur/` layout,
  # so the canonical templates live under `.aiur/examples/` in this repo.
  @example_path Path.expand("../../../../.aiur/examples/config.example", __DIR__)
  @external_resource @example_path
  @example_template File.read!(@example_path)

  # The scaffolded config references hooks via `hooks_file: hooks`, so init also
  # writes a `.aiur/hooks` (from `.aiur/examples/hooks.example`) next to the config
  # — otherwise the first run would fail resolving a missing hooks file. Embedded at
  # compile time so the wizard works from a release with no runtime file dependency.
  @prewarm_file_name "prewarm"

  # ISO-639-3, the code family the ElevenLabs speech-to-text API expects.
  @elevenlabs_language_code "eng"
  @aiurhooks_example_path Path.expand("../../../../.aiur/examples/hooks.example", __DIR__)
  @external_resource @aiurhooks_example_path
  @aiurhooks_example_template File.read!(@aiurhooks_example_path)

  # The scaffolded config references the alert sound map via `alerts_file: alerts`,
  # so init also writes an extensionless `.aiur/alerts` next to the config —
  # matching the `.aiur/` convention where config-like files have no extension.
  # macOS and Linux ship different system sounds, so there is one filled example
  # per platform and init scaffolds the host's. Embedded at compile time so the
  # wizard works from a release with no runtime file dependency.
  @alerts_macos_example_path Path.expand("../../../../.aiur/examples/alerts.macos.example", __DIR__)
  @alerts_linux_example_path Path.expand("../../../../.aiur/examples/alerts.linux.example", __DIR__)
  @external_resource @alerts_macos_example_path
  @external_resource @alerts_linux_example_path
  @alerts_macos_example_template File.read!(@alerts_macos_example_path)
  @alerts_linux_example_template File.read!(@alerts_linux_example_path)

  @spec config_example() :: String.t()
  def config_example, do: @example_template

  @spec env_content() :: String.t()
  def env_content, do: @env_content

  @doc "Raw .aiurhooks template that `aiur init` scaffolds."
  @spec aiurhooks_template() :: String.t()
  def aiurhooks_template, do: @aiurhooks_example_template

  @doc "Raw alert sound map template that `aiur init` scaffolds as `.aiur/alerts`."
  @spec alerts_template() :: String.t()
  def alerts_template, do: alerts_template(:os.type())

  @doc false
  @spec alerts_template({atom(), atom()} | term()) :: String.t()
  def alerts_template({:unix, :darwin}), do: @alerts_macos_example_template
  def alerts_template({:unix, _}), do: @alerts_linux_example_template
  def alerts_template(_os_type), do: @alerts_linux_example_template

  @doc "Raw prompt_file template (with the `{{REPO}}` placeholder) that `aiur init` scaffolds."
  @spec prompt_file_template() :: String.t()
  def prompt_file_template, do: @prompt_example_template

  @doc "Raw executor handoff template that `aiur init` seeds in the repository state node."
  @spec executor_handoff_template() :: String.t()
  def executor_handoff_template, do: @executor_handoff_example_template

  @doc "Prompt_file scaffold with the repo placeholder filled for `repo` (or a neutral fallback)."
  @spec prompt_file_scaffold(String.t() | nil) :: String.t()
  def prompt_file_scaffold(repo) do
    String.replace(@prompt_example_template, @repo_placeholder, repo_display(repo))
  end

  @spec build_fills(map()) :: map()
  def build_fills(d) do
    %{
      "{{TRACKER_KIND}}" => d.tracker.kind,
      "{{BASE_BRANCH}}" => d.tracker |> Aiur.Config.base_branch() |> Jason.encode!(),
      "{{TRACKER_PROVIDER}}" => tracker_provider_block(d.tracker),
      "{{AGENT_KIND}}" => Questions.primary_kind(d.agents),
      "{{PRIORITY}}" => priority_inline(d.agents),
      "{{MAX_AGENTS}}" => Integer.to_string(d.max_agents),
      "{{MAX_TURNS}}" => to_string(d.max_turns),
      "{{MAX_AGENT_DURATION}}" => Integer.to_string(d.max_duration),
      "{{ROUTING}}" => routing_inline(d.routing),
      "{{PERMISSION_MODE}}" => d.permission_mode,
      "{{WORKSPACE_ROOT}}" => d.workspace_root,
      "{{PROMPT_FILE}}" => d.prompt_file,
      "{{POLLING}}" => Integer.to_string(d.polling),
      "{{PRE_WARMED}}" => Integer.to_string(d.pre_warmed),
      "{{PREWARM_ENABLED}}" => to_string(d.prewarm.enabled),
      "{{PREWARM_BASE_BUILD_FILE}}" => prewarm_base_build_file_line(d.prewarm),
      "{{ALERTS_ENABLED}}" => to_string(d.alerts.enabled),
      "{{ALERTS_OS_SOUNDS}}" => to_string(d.alerts.use_os_default_sounds),
      "{{ELEVENLABS_API_KEY}}" => elevenlabs_api_key_line(d.elevenlabs),
      "{{ELEVENLABS_LANGUAGE}}" => @elevenlabs_language_code
    }
  end

  @spec fill_template(String.t(), map()) :: String.t()
  def fill_template(template, fills) do
    Enum.reduce(fills, template, fn {token, value}, acc ->
      String.replace(acc, token, to_string(value))
    end)
  end

  defp prewarm_base_build_file_line(%{enabled: true, base_build: cmd}) when is_binary(cmd) and cmd != "",
    do: "  base_build_file: #{@prewarm_file_name}\n"

  defp prewarm_base_build_file_line(_), do: ""

  # Written only when the operator opted in, so a declined voice-input question
  # leaves the credential line out entirely (no empty `api_key:` to resolve).
  defp elevenlabs_api_key_line(%{enabled: true, api_key: key}) when is_binary(key) and key != "",
    do: "  api_key: #{String.trim(key)}\n"

  defp elevenlabs_api_key_line(_), do: ""

  defp tracker_provider_block(%{kind: "github"} = github) do
    # label_prefix is fixed (`agent`) and matches the schema default, so the
    # written config omits it. bot_account is the identity (not the GITHUB_TOKEN
    # credential) Aiur suppresses to avoid self-loops; omitted when left blank.
    [
      "  github:",
      github[:repo] && "    repo: #{github[:repo]}",
      github[:bot_account] && "    bot_account: #{github[:bot_account]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tracker_provider_block(%{kind: "linear", api_key: api_key, project_slug: slug}) do
    [
      "  linear:",
      api_key && "    api_key: #{api_key}",
      slug && "    project_slug: #{slug}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tracker_provider_block(_tracker), do: ""

  defp routing_inline(routing) do
    "{" <> Enum.map_join(1..5, ", ", fn level -> "#{level}: #{Map.fetch!(routing, level)}" end) <> "}"
  end

  defp priority_inline(agents) do
    "[" <> Enum.join(agents, ", ") <> "]"
  end

  defp repo_display(repo) when is_binary(repo) do
    case String.trim(repo) do
      "" -> "current"
      trimmed -> trimmed
    end
  end

  defp repo_display(_repo), do: "current"
end
