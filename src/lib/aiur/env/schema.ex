defmodule Aiur.Env.Schema do
  @moduledoc """
  Declarative schema of every environment variable the Aiur app reads.

  This is the single source of truth for an environment variable's name, type
  (`:string` / `:integer` / `:boolean` / `:path` / `:secret`), requiredness,
  implicit default, secret-ness, and its one-line documentation. Three things
  are built from it and nothing else:

    * **Startup validation** (`Aiur.Env.validate/1`, `Aiur.Env.validate_startup!/1`):
      missing required credentials and values that fail their type abort the
      boot naming the variable, instead of failing at first use hours later.
    * **`.env.example` generation** (`Aiur.Env.render_example/0`): the checked-in
      example file is rendered from the schema, so names, purpose lines and
      fetch notes cannot drift. Real values are never rendered; secrets stay
      empty.
    * **Drift check** (`scripts/check-env-example.py`): the CI check fails when
      `.env.example` disagrees with this schema.

  Every entry also carries the operator-facing documentation fields the
  generated example renders: `purpose` (one line above the key) and `fetch`
  (a terse right-hand "how to get it" note). The schema is self-validated with
  `NimbleOptions` at load so a malformed declaration fails loudly in tests
  rather than at boot.

  ## Requiredness model

  The only configuration that may abort a boot is the GitHub credential
  (`GITHUB_TOKEN`, or a complete GitHub App credential set — see
  `github_credential_requirement/0`). Every integration — GitHub App auth,
  webhooks, Linear, voice, dashboard, Decision API, provider keys — is
  optional and absent degrades to "feature off", never to a guard being
  skipped. Credential *groups* (`github_app`, `dashboard`) are all-or-nothing:
  a partial group is a misconfiguration that fails at startup naming the
  missing member; a fully absent group is a supported setup. See
  `credential_groups/0`.
  """

  # --- Groups rendered in .env.example -------------------------------------

  @doc "Group id → the `##` header rendered in `.env.example`. `nil` = no section."
  @spec groups() :: [{atom(), String.t() | nil}]
  def groups do
    [
      required: "Required",
      github_app: "Optional - GitHub App auth. Gives the daemon its own rate-limit budget and a bot identity.",
      webhook: "Optional - Webhooks. Cuts API polling; needs a public URL reaching this daemon.",
      linear: "Optional - Linear tracker. Use Linear instead of GitHub as the issue tracker.",
      voice: "Optional - Voice. Mic input and spoken replies on dashboard and Stream Deck.",
      dashboard: "Optional - Aiur dashboard. Web UI at :4000; CLI and TUI work without it.",
      decision_api: "Optional - Supervisor Decision API. Dedicated bearer credential for Executor automation.",
      provider_keys: "Optional - Provider API keys. Named by agent.backend_configs.<backend>.api_key_env.",
      runtime: "Runtime - launcher-managed. Normally set by `aiur` itself, not by hand.",
      dev: "Development and debugging.",
      ambient: nil
    ]
  end

  @doc """
  Credential groups that are all-or-nothing.

  A group is *active* when any of its members is set. When active, every
  member in `members` must be set — except that exactly one of each
  `one_of` alternative set must be set. When inactive (all members absent),
  the group is a supported "feature off" setup and never an error. A partial
  group is a startup failure naming the missing member(s).
  """
  @spec credential_groups() :: %{
          atom() => %{
            members: [String.t()],
            one_of: [[String.t()]],
            missing_message: (String.t() -> String.t())
          }
        }
  def credential_groups do
    %{
      github_app: %{
        members: [
          "GITHUB_APP_ID",
          "GITHUB_APP_INSTALLATION_ID",
          "GITHUB_APP_PRIVATE_KEY_PATH",
          "GITHUB_APP_PRIVATE_KEY"
        ],
        one_of: [["GITHUB_APP_PRIVATE_KEY_PATH", "GITHUB_APP_PRIVATE_KEY"]],
        missing_message: fn missing ->
          "GitHub App credentials are partially configured; missing " <>
            "#{Enum.join(missing, ", ")}. Set the complete set or none."
        end
      },
      dashboard: %{
        members: ["AIUR_DASHBOARD_USERNAME", "AIUR_DASHBOARD_PASSWORD"],
        one_of: [],
        missing_message: fn missing ->
          "Dashboard credentials are partially configured; missing #{Enum.join(missing, ", ")}. Set both or neither."
        end
      }
    }
  end

  @doc """
  The only boot-aborting credential requirement.

  The daemon must be able to authenticate with GitHub. `GITHUB_TOKEN` alone
  satisfies it; otherwise the complete `github_app` credential group
  (`github_credential_groups`) must be present. Absence is a startup failure
  naming what is missing; the tracker configuration requirement is enforced
  separately by `Aiur.Config.validate!/0`.
  """
  @spec github_credential_requirement() :: %{
          token: String.t(),
          alternative_group: atom(),
          missing_message: String.t()
        }
  def github_credential_requirement do
    %{
      token: "GITHUB_TOKEN",
      alternative_group: :github_app,
      missing_message:
        "no GitHub credential is configured: set GITHUB_TOKEN, or configure the " <>
          "complete GitHub App set (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and " <>
          "one of GITHUB_APP_PRIVATE_KEY_PATH / GITHUB_APP_PRIVATE_KEY)"
    }
  end

  # --- The declarations -----------------------------------------------------

  # Each entry: {name, spec} where spec keys are validated by NimbleOptions
  # against @spec_entry_schema below. Keep `purpose` to one line and `fetch` a
  # terse A -> B -> C note (or nil when there is nothing to fetch). Names must
  # be the only line-leading "UPPERCASE" string literals in this file —
  # scripts/check-env-example.py parses them to detect drift.
  @specs [
    {"GITHUB_TOKEN",
     type: :secret,
     required: true,
     group: :required,
     purpose: "Fallback GitHub credential; ignored when the GitHub App vars below are set.",
     fetch: "github.com/settings/tokens -> Generate -> repo scope"},

    # --- GitHub App auth ---
    {"GITHUB_APP_ID", type: :string, group: :github_app, purpose: "GitHub App numeric id; preferred auth, short-lived installation tokens.", fetch: "App settings page, top of page"},
    {"GITHUB_APP_INSTALLATION_ID", type: :string, group: :github_app, purpose: "Which installation of the App to authenticate as.", fetch: "Install App -> number at end of URL"},
    {"GITHUB_APP_PRIVATE_KEY_PATH",
     type: :path, secret: true, group: :github_app, purpose: "Path to the App private key PEM; keeps the key out of the env.", fetch: "App settings -> Generate a private key -> save, chmod 600"},
    {"GITHUB_APP_PRIVATE_KEY", type: :secret, group: :github_app, purpose: "Inline PEM alternative to the path above; set one, not both."},

    # --- Webhooks ---
    {"AIUR_GITHUB_WEBHOOK_SECRET",
     type: :secret, group: :webhook, purpose: "Secret GitHub signs webhook deliveries with; unset rejects every delivery.", fetch: "openssl rand -hex 32 -> paste into repo webhook"},

    # --- Linear tracker ---
    {"LINEAR_API_KEY", type: :secret, group: :linear, purpose: "Linear API key when the tracker is Linear.", fetch: "linear.app/settings/api -> personal API key"},
    {"LINEAR_ASSIGNEE", type: :string, group: :linear, purpose: "Assignee Linear issues are assigned to by default."},

    # --- Voice ---
    {"ELEVENLABS_API_KEY", type: :secret, group: :voice, purpose: "Speech-to-text for dashboard and Stream Deck mics.", fetch: "elevenlabs.io -> Profile -> API Keys"},

    # --- Dashboard ---
    {"AIUR_DASHBOARD_USERNAME", type: :string, group: :dashboard, purpose: "Dashboard Basic Auth user; both credentials together.", fetch: "see guide/gui"},
    {"AIUR_DASHBOARD_PASSWORD", type: :secret, group: :dashboard, purpose: "Dashboard Basic Auth password; unset makes the dashboard refuse all requests.", fetch: "see guide/gui"},

    # --- Supervisor Decision API ---
    {"AIUR_SUPERVISOR_TOKEN", type: :secret, group: :decision_api, purpose: "Bearer token for the Supervisor Decision API; unset refuses those requests.", fetch: "openssl rand -base64 32"},
    {"AIUR_CI_READINESS_TOKEN", type: :secret, group: :decision_api, purpose: "Operator token `aiur init` uses to confirm PRs can auto-merge."},

    # --- Provider API keys ---
    {"DEEPSEEK_API_KEY", type: :secret, group: :provider_keys, purpose: "DeepSeek backend key; used when a backend config names this env var.", fetch: "platform.deepseek.com -> API Keys"},
    {"MOONSHOT_API_KEY", type: :secret, group: :provider_keys, purpose: "Moonshot backend key; used when a backend config names this env var."},
    {"OPENROUTER_API_KEY", type: :secret, group: :provider_keys, purpose: "OpenRouter backend key; used when a backend config names this env var.", fetch: "openrouter.ai -> Keys -> Create key"},
    {"OPENROUTER_MANAGEMENT_KEY", type: :secret, group: :provider_keys, purpose: "OpenRouter usage-management key; used when a backend config names this env var."},

    # --- Runtime (launcher-managed) ---
    {"AIUR_BG_STATE_DIR", type: :path, group: :runtime, purpose: "Directory for cookie, state and per-instance files.", default: "~/.config/aiur"},
    {"AIUR_LOGS_ROOT", type: :path, group: :runtime, purpose: "Directory for daemon logs."},
    {"AIUR_TMUX_SESSION", type: :string, group: :runtime, purpose: "tmux session name the launcher uses."},
    {"AIUR_TMUX_SOCKET", type: :string, group: :runtime, purpose: "tmux socket name the launcher uses."},
    {"AIUR_ERLANG_COOKIE", type: :secret, group: :runtime, purpose: "BEAM distribution cookie; launcher generates one if unset.", fetch: "openssl rand -hex 32"},
    {"AIUR_INSTANCE_KEY", type: :string, validate: false, example: false, group: :runtime, purpose: "Per-instance key hashing the project root; set by the launcher."},
    {"AIUR_NOFILE_SOFT_LIMIT", type: :integer, validate: false, example: false, group: :runtime, purpose: "Effective open-file soft limit; exported by the launcher."},
    {"AIUR_AGENT_TMPFILE", type: :path, validate: false, example: false, group: :runtime, purpose: "Agent-queue tempfile path; set by the launcher."},
    {"AIUR_SESSION_TMPFILE", type: :path, validate: false, example: false, group: :runtime, purpose: "Session tempfile path; set by the launcher."},
    {"AIUR_WORKSPACE_ROOT_FILE", type: :path, validate: false, example: false, group: :runtime, purpose: "File the launcher reads the workspace root from."},
    {"AIUR_ALERT_LEDGER_PATH_FILE", type: :path, validate: false, example: false, group: :runtime, purpose: "File the launcher reads the alert ledger path from."},
    {"AIUR_ARGV_FILE", type: :path, validate: false, example: false, group: :runtime, purpose: "File carrying the CLI argv; set by the launcher shim."},
    {"AIUR_CLI_VERSION", type: :string, validate: false, example: false, group: :runtime, purpose: "Installed CLI package version; set by the launcher."},
    {"AIUR_AGENT_WORKSPACE", type: :path, validate: false, example: false, group: :runtime, purpose: "Agent workspace root; guards `test.reset` from inside an agent."},
    {"AIUR_OPERATOR_PID", type: :integer, validate: false, example: false, group: :runtime, purpose: "Shell that launched aiur; exported by the launcher."},
    {"AIUR_LAUNCHER_PID", type: :integer, validate: false, example: false, group: :runtime, purpose: "Launcher process id; exported by the launcher."},
    {"AIUR_GITHUB_BUDGET_CONSUMER", type: :string, validate: false, example: false, group: :runtime, purpose: "Workspace budget consumer id; set by the launcher."},
    {"AIUR_GITHUB_BUDGET_IDENTITY_KEY", type: :string, validate: false, example: false, group: :runtime, purpose: "Stable publication-credential budget identity; set by the launcher."},
    {"AIUR_AGENT_IR_SANDBOX", type: :boolean, validate: false, example: false, group: :runtime, purpose: "Test-reset guard inside an agent IR sandbox."},
    {"AIUR_TELEMETRY_CALLER_CWD", type: :path, validate: false, example: false, group: :runtime, purpose: "Working directory captured by the telemetry CLI wrapper."},
    {"AIUR_RELEASE_DIR", type: :path, validate: false, example: false, group: :runtime, purpose: "Release directory the launcher resolved; detects a dev launcher run."},

    # --- Development and debugging ---
    {"AIUR_DEBUG", type: :boolean, group: :dev, default: false, purpose: "Enable debug logging (1 / true / yes)."},
    {"AIUR_SCREEN_GRAB", type: :boolean, validate: false, example: false, group: :dev, purpose: "Enable per-pane screen-grab diagnostics."},
    {"AIUR_PREWARM_DISABLED", type: :boolean, group: :dev, default: false, purpose: "Disable opencode pre-warm (1 / true / yes)."},
    {"AIUR_OPENCODE_BRIDGE_PORT", type: :integer, group: :dev, purpose: "opencode-serve bridge port; picked automatically when unset."},
    {"AIUR_SSH_CONFIG", type: :path, group: :dev, purpose: "Custom ssh config path used for git operations."},
    {"AIUR_DEFAULT_DASHBOARD_HOST", type: :string, group: :dev, default: "127.0.0.1", purpose: "Default dashboard bind host when server.host is unset."},
    {"AIUR_BASE_BRANCH", type: :string, group: :dev, purpose: "Authoritative integration branch for PRs and affected-test scoping."},
    {"AIUR_EXECUTOR_ID", type: :string, group: :dev, purpose: "Pins the executor wake-stream owner when multiple daemons share a repository."},
    {"AIUR_BUILD_ORDER_DIRS", type: :string, validate: false, example: false, group: :dev, purpose: "Colon-separated build-order pack dirs; dev/test override."},
    {"AIUR_REGISTRY_URL", type: :string, validate: false, example: false, group: :dev, purpose: "Upgrade registry endpoint override (tests and mirrors)."},

    # --- Ambient (read, not operator-configured) ---
    {"PATH", type: :path, validate: false, example: false, group: :ambient, purpose: "Executable search path inherited by child processes."},
    {"HOME", type: :path, validate: false, example: false, group: :ambient, purpose: "Home directory for user-scoped state."},
    {"COLUMNS", type: :integer, validate: false, example: false, group: :ambient, default: 80, purpose: "Terminal width for the agent list renderer."},
    {"LINES", type: :integer, validate: false, example: false, group: :ambient, default: 24, purpose: "Terminal height for the agent list renderer."},
    {"COLORTERM", type: :string, validate: false, example: false, group: :ambient, purpose: "Terminal color capability for the agent list renderer."},
    {"TMUX_PANE", type: :string, validate: false, example: false, group: :ambient, purpose: "tmux pane id the daemon runs in."},
    {"XDG_CONFIG_HOME", type: :path, validate: false, example: false, group: :ambient, purpose: "Config base for user-scoped configuration."},
    {"XDG_STATE_HOME", type: :path, validate: false, example: false, group: :ambient, purpose: "State base for user-scoped state."},
    {"MISE_DATA_DIR", type: :path, validate: false, example: false, group: :ambient, purpose: "mise data directory for toolchain paths."},
    {"TMPDIR", type: :path, validate: false, example: false, group: :ambient, purpose: "System temp directory."},
    {"TEMP", type: :path, validate: false, example: false, group: :ambient, purpose: "System temp directory (Windows-style alias)."},
    {"TMP", type: :path, validate: false, example: false, group: :ambient, purpose: "System temp directory (alias)."},
    {"ELIXIR_ERL_OPTIONS", type: :string, validate: false, example: false, group: :ambient, purpose: "Scheduler options inherited by launched BEAMs."},
    {"ERL_EPMD_ADDRESS", type: :string, validate: false, example: false, group: :ambient, purpose: "epmd bind address for distribution."},
    {"GIT_AUTHOR_EMAIL", type: :string, validate: false, example: false, group: :ambient, purpose: "Author email for commits made by agents."},
    {"GIT_AUTHOR_NAME", type: :string, validate: false, example: false, group: :ambient, purpose: "Author name for commits made by agents."},
    {"CI", type: :string, validate: false, example: false, group: :ambient, purpose: "CI runner signal; suppresses the update notifier."}
  ]

  # NimbleOptions.validate!/2 returns the declaration as a keyword list with
  # defaults filled in, so `spec` is a keyword list of atom keys, not a map.
  @type type :: :string | :integer | :boolean | :path | :secret
  @type spec :: keyword()

  @spec_entry_schema [
    type: [type: {:in, [:string, :integer, :boolean, :path, :secret]}, required: true],
    required: [type: :boolean, default: false],
    secret: [type: :boolean, default: false],
    default: [type: :any],
    group: [type: :atom],
    validate: [type: :boolean, default: true],
    example: [type: :boolean, default: true],
    emit_default: [type: :boolean, default: false],
    purpose: [type: :string, required: true],
    fetch: [type: :string]
  ]

  @validated_specs Enum.map(@specs, fn {name, spec} ->
                     {name, NimbleOptions.validate!(spec, @spec_entry_schema)}
                   end)

  @doc """
  The validated spec entries, `{name, spec}`, in declaration order.
  """
  @spec specs() :: [{String.t(), spec()}]
  def specs, do: @validated_specs

  @doc "Every env var name declared in the schema."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@validated_specs, &elem(&1, 0))

  @doc "The spec for `name`, or `nil` when it is not declared."
  @spec spec_for(String.t()) :: spec() | nil
  def spec_for(name), do: Enum.find_value(@validated_specs, fn {n, spec} -> if n == name, do: spec end)

  @doc "Specs whose value should be rendered in `.env.example` (non-ambient, non-launcher-internal)."
  @spec example_specs() :: [{String.t(), spec()}]
  def example_specs, do: Enum.filter(@validated_specs, fn {_name, spec} -> spec[:example] end)

  @doc "Names that should appear in `.env.example`."
  @spec example_names() :: [String.t()]
  def example_names, do: Enum.map(example_specs(), &elem(&1, 0))

  @doc "Secret var names, for redaction and placeholder rendering."
  @spec secret_names() :: [String.t()]
  def secret_names do
    Enum.filter(@validated_specs, fn {_name, spec} -> spec[:type] == :secret or spec[:secret] end)
    |> Enum.map(&elem(&1, 0))
  end
end
