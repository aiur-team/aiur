defmodule Aiur.GitHub.Access.Settings do
  @moduledoc "Configuration supplied by the embedding application, without application-owned structs."

  @enforce_keys [:state_root]
  defstruct [
    :state_root,
    :budget_dir,
    :request_log_dir,
    :quota_dir,
    :resource_store_path,
    :probe_dir,
    :repo,
    :app_account,
    :bot_account,
    api_base_url: "https://api.github.com",
    graphql_url: "https://api.github.com/graphql",
    credentials: [],
    budget: %{},
    budget_enabled?: true,
    cache: %{},
    broker_timeout: %{budget_broker_rate_window_seconds: 300, budget_broker_degraded_retry_threshold: 5, budget_broker_degraded_alert_after_seconds: 600},
    alert_sink: &Aiur.Signal.alert/2
  ]

  @type t :: %__MODULE__{}

  @doc "Build standalone settings with every durable path beneath the given root."
  @spec new(Path.t(), keyword()) :: t()
  def new(root, overrides \\ []) do
    root = Path.expand(root)

    struct!(
      %__MODULE__{
        state_root: root,
        budget_dir: Path.join(root, "github-budget"),
        request_log_dir: Path.join(root, "github-quota"),
        quota_dir: Path.join(root, "github-quota"),
        resource_store_path: Path.join(root, "github_resources.json"),
        probe_dir: Path.join(root, "workspaces/__github_quota_probe__")
      },
      overrides
    )
  end

  @doc "Read the provider on every call, preserving the embedding application's reload policy."
  @spec current() :: t()
  def current do
    case Application.get_env(:aiur, :github_access_settings_provider) do
      nil -> raise ArgumentError, "configure :aiur, :github_access_settings_provider before using GitHub access"
      provider -> provider.settings()
    end
  end
end
