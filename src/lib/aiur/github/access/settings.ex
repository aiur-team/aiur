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
    :config_error,
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
  @type path_field :: :state_root | :budget_dir | :quota_dir | :request_log_dir | :resource_store_path | :probe_dir

  @request_key {__MODULE__, :request_snapshot}

  @doc "Run a function with one settings snapshot shared by nested accessors."
  @spec with_request((-> result)) :: result when result: term()
  def with_request(fun) when is_function(fun, 0) do
    if Process.get(@request_key) do
      fun.()
    else
      previous = Process.get(@request_key, :unset)
      snapshot = current()
      Process.put(@request_key, snapshot)

      try do
        fun.()
      after
        if previous == :unset, do: Process.delete(@request_key), else: Process.put(@request_key, previous)
      end
    end
  end

  @doc "Resolve a path only when its consumer needs it; providers may supply zero-arity resolvers."
  @spec path(path_field()) :: Path.t() | nil
  def path(field) do
    case Map.fetch!(current(), field) do
      resolve when is_function(resolve, 0) -> resolve.()
      value -> value
    end
  end

  @doc "Resolve a path from an already captured request snapshot."
  @spec path(t(), path_field()) :: Path.t() | nil
  def path(%__MODULE__{} = snapshot, field) do
    case Map.fetch!(snapshot, field) do
      resolve when is_function(resolve, 0) -> resolve.()
      value -> value
    end
  end

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
    case Process.get(@request_key) do
      nil ->
        case Application.get_env(:aiur, :github_access_settings_provider) do
          nil -> raise ArgumentError, "configure :aiur, :github_access_settings_provider before using GitHub access"
          provider -> provider.settings()
        end

      snapshot ->
        snapshot
    end
  end
end
