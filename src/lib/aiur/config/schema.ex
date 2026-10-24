defmodule Aiur.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.Config.CodexSandboxPolicy

  alias Aiur.Config.Schema.{
    Agent,
    Alerts,
    Attrs,
    BuildOrder,
    BuildQueue,
    Codex,
    Compaction,
    Decisions,
    ElevenLabs,
    EnvResolver,
    Errors,
    Events,
    Executor,
    Experiments,
    Hooks,
    Instance,
    MergePolicy,
    Monitoring,
    Observability,
    Opencode,
    Polling,
    Prewarm,
    PrHealth,
    PrWatch,
    Server,
    Tracker,
    Upgrade,
    Voice,
    Webhooks,
    Worker,
    Workspace
  }

  # Embedded struct defaults must rebuild when their nested schemas change.
  require Agent
  require Instance
  require Tracker
  require BuildQueue
  require Experiments
  require Voice
  require Workspace

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-00 max_vertical_panes
    # @config-detail max_vertical_panes | integer | 3 | Caps visible agent chat panes. |
    field(:max_vertical_panes, :integer, default: 3)
    # @config-reference config-configuration-00 pre_warmed_sessions
    # @config-detail pre_warmed_sessions | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
    field(:pre_warmed_sessions, :integer, default: 3)
    # @config-reference config-configuration-00 max_log_history_mb
    # @config-detail max_log_history_mb | integer | 1000 | Caps persistent log history in MB. |
    field(:max_log_history_mb, :integer, default: 1000)
    # @config-reference config-configuration-00 prompt_file
    # @config-detail prompt_file | string | nil | Per-repository Liquid prompt template. |
    # @config-reference config-configuration-00 hooks_file
    # @config-detail hooks_file | file pointer | none | Sibling YAML file merged as the `hooks:` block. |
    field(:prompt_file, :string)
    # @config-reference config-configuration-00 debug
    # @config-detail debug | boolean | false | Enables debug-level file logging without the CLI debug flag; background runs already retain normal-level logs. |
    field(:debug, :boolean, default: false)
    # Configurable Executor takeover advisory alerts (#1182). `0` disables the
    # corresponding alert; negative values are rejected by the changeset.
    # @config-reference config-configuration-00 executor_takeover_first_alert_hours
    # @config-detail executor_takeover_first_alert_hours | integer | 8 | First Executor takeover advisory threshold in hours; `0` disables. |
    field(:executor_takeover_first_alert_hours, :integer, default: 8)
    # @config-reference config-configuration-00 executor_takeover_continuous_alert_hours
    # @config-detail executor_takeover_continuous_alert_hours | integer | 1 | Repeated takeover advisory cadence in hours after the first; `0` disables repeats. |
    field(:executor_takeover_continuous_alert_hours, :integer, default: 1)

    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:instance, Instance, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:compaction, Compaction, on_replace: :update, defaults_to_struct: true)
    embeds_one(:decisions, Decisions, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:merge_policy, MergePolicy, on_replace: :update, defaults_to_struct: true)
    embeds_one(:monitoring, Monitoring, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:opencode, Opencode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:experiments, Experiments, on_replace: :update, defaults_to_struct: true)
    embeds_one(:events, Events, on_replace: :update, defaults_to_struct: true)
    # Keep new prewarm defaults present even when a config omits the whole block.
    embeds_one(:prewarm, Prewarm, on_replace: :update, defaults_to_struct: true)
    embeds_one(:alerts, Alerts, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr_health, PrHealth, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr_watch, PrWatch, on_replace: :update, defaults_to_struct: true)
    embeds_one(:build_queue, BuildQueue, on_replace: :update, defaults_to_struct: true)
    embeds_one(:build_order, BuildOrder, on_replace: :update, defaults_to_struct: true)
    embeds_one(:webhooks, Webhooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:elevenlabs, ElevenLabs, on_replace: :update, defaults_to_struct: true)
    embeds_one(:voice, Voice, on_replace: :update, defaults_to_struct: true)
    embeds_one(:upgrade, Upgrade, on_replace: :update, defaults_to_struct: true)
    # Keep the Executor sweep settings in the same parsed settings snapshot.
    embeds_one(:executor, Executor, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config = config |> Attrs.normalize_keys() |> Attrs.drop_nil_values()

    with :ok <- reject_obsolete_root_sections(config) do
      config
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, settings} ->
          {:ok, finalize_settings(settings)}

        {:error, changeset} ->
          {:error, {:invalid_workflow_config, Errors.format_errors(changeset)}}
      end
    end
  end

  defp reject_obsolete_root_sections(%{"codex" => _}) do
    {:error, {:invalid_workflow_config, "codex is no longer supported at the workflow root; move its settings to agent.codex"}}
  end

  defp reject_obsolete_root_sections(_config), do: :ok

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    CodexSandboxPolicy.resolve(
      effective_turn_sandbox_policy(settings.agent.codex),
      workspace,
      settings.workspace.root
    )
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    CodexSandboxPolicy.resolve_runtime(
      effective_turn_sandbox_policy(settings.agent.codex),
      workspace,
      settings.workspace.root,
      opts
    )
  end

  @doc false
  @spec add_runtime_turn_sandbox_roots(map(), [Path.t()]) :: {:ok, map()} | {:error, term()}
  def add_runtime_turn_sandbox_roots(policy, roots) do
    CodexSandboxPolicy.add_runtime_writable_roots(policy, roots)
  end

  @doc false
  @spec workspace_write_policy?(map()) :: boolean()
  def workspace_write_policy?(policy) do
    (Map.get(policy, "type") || Map.get(policy, :type)) == "workspaceWrite"
  end

  @doc false
  @spec policy_writable_roots(map()) :: {:ok, list()} | {:error, term()}
  def policy_writable_roots(policy) do
    case Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || [] do
      roots when is_list(roots) -> {:ok, roots}
      roots -> {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_roots, roots}}}
    end
  end

  @doc false
  @spec validate_turn_sandbox_policy(%__MODULE__{}) :: :ok | {:error, term()}
  def validate_turn_sandbox_policy(settings) do
    settings.agent.codex
    |> effective_turn_sandbox_policy()
    |> CodexSandboxPolicy.validate_configured_writable_roots()
  end

  defp effective_turn_sandbox_policy(%Codex{turn_sandbox_policy: nil, thread_sandbox: thread_sandbox})
       when is_binary(thread_sandbox) do
    case String.trim(thread_sandbox) do
      "danger-full-access" -> %{"type" => "dangerFullAccess"}
      _ -> nil
    end
  end

  defp effective_turn_sandbox_policy(%Codex{turn_sandbox_policy: policy}), do: policy

  defp changeset(attrs) do
    # Run the section changeset even when absent, so epic defaults are applied.
    attrs = Map.put_new(attrs, "build_order", %{})

    %__MODULE__{}
    |> cast(
      attrs,
      [
        :max_vertical_panes,
        :pre_warmed_sessions,
        :max_log_history_mb,
        :prompt_file,
        :debug,
        :executor_takeover_first_alert_hours,
        :executor_takeover_continuous_alert_hours
      ],
      empty_values: []
    )
    |> validate_number(:max_vertical_panes, greater_than: 0)
    |> validate_number(:pre_warmed_sessions, greater_than_or_equal_to: 0)
    |> validate_number(:max_log_history_mb, greater_than: 0)
    |> validate_number(:executor_takeover_first_alert_hours, greater_than_or_equal_to: 0)
    |> validate_number(:executor_takeover_continuous_alert_hours, greater_than_or_equal_to: 0)
    |> validate_raw_non_negative_integer(attrs, "executor_takeover_first_alert_hours")
    |> validate_raw_non_negative_integer(attrs, "executor_takeover_continuous_alert_hours")
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:instance, with: &Instance.changeset/2)
    |> cast_embed(:executor, with: &Executor.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:compaction, with: &Compaction.changeset/2)
    |> cast_embed(:decisions, with: &Decisions.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:merge_policy, with: &MergePolicy.changeset/2)
    |> cast_embed(:monitoring, with: &Monitoring.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:opencode, with: &Opencode.changeset/2)
    |> cast_embed(:experiments, with: &Experiments.changeset/2)
    |> cast_embed(:events, with: &Events.changeset/2)
    |> cast_embed(:prewarm, with: &Prewarm.changeset/2)
    |> cast_embed(:alerts, with: &Alerts.changeset/2)
    |> cast_embed(:pr_health, with: &PrHealth.changeset/2)
    |> cast_embed(:pr_watch, with: &PrWatch.changeset/2)
    |> cast_embed(:build_queue, with: &BuildQueue.changeset/2)
    |> cast_embed(:build_order, with: &BuildOrder.changeset/2)
    |> cast_embed(:webhooks, with: &Webhooks.changeset/2)
    |> cast_embed(:elevenlabs, with: &ElevenLabs.changeset/2)
    |> cast_embed(:voice, with: &Voice.changeset/2)
    |> cast_embed(:upgrade, with: &Upgrade.changeset/2)
  end

  # Ecto's integer cast truncates a float (1.5 -> 1) and coerces a numeric
  # string ("1" -> 1), silently accepting config mistakes for fields that are
  # documented as whole-hour integers. Inspect the raw pre-cast value and
  # reject anything that is not an integer >= 0 with a clear error.
  defp validate_raw_non_negative_integer(changeset, attrs, key) do
    case Map.get(attrs, key) do
      nil -> changeset
      value when is_integer(value) and value >= 0 -> changeset
      _other -> Ecto.Changeset.add_error(changeset, String.to_atom(key), "must be a non-negative integer")
    end
  end

  defp finalize_settings(settings) do
    linear = %{
      settings.tracker.linear
      | api_key:
          EnvResolver.resolve_secret_setting(
            settings.tracker.linear.api_key,
            System.get_env("LINEAR_API_KEY")
          ),
        assignee:
          EnvResolver.resolve_secret_setting(
            settings.tracker.linear.assignee,
            System.get_env("LINEAR_ASSIGNEE")
          )
    }

    tracker = %{settings.tracker | linear: linear}

    workspace = %{
      settings.workspace
      | root:
          EnvResolver.resolve_path_value(
            settings.workspace.root,
            Path.join(System.tmp_dir!(), "aiur_workspaces")
          )
    }

    codex = %{
      settings.agent.codex
      | approval_policy: Attrs.normalize_keys(settings.agent.codex.approval_policy),
        turn_sandbox_policy: Attrs.normalize_optional_map(settings.agent.codex.turn_sandbox_policy)
    }

    agent = %{settings.agent | codex: codex, mix_scheduler_cap: settings.agent.mix_scheduler_cap || 4}

    elevenlabs = resolve_elevenlabs(settings.elevenlabs)
    instance = %{settings.instance | ignore: settings.instance.ignore || %Aiur.Config.Schema.Instance.Ignore{}}

    %{settings | tracker: tracker, workspace: workspace, agent: agent, elevenlabs: elevenlabs, instance: instance}
  end

  defp resolve_elevenlabs(%ElevenLabs{enabled: false} = elevenlabs),
    do: %{elevenlabs | api_key: nil}

  defp resolve_elevenlabs(elevenlabs) do
    %{
      elevenlabs
      | api_key:
          EnvResolver.resolve_secret_setting(
            elevenlabs.api_key,
            System.get_env("ELEVENLABS_API_KEY")
          )
    }
  end
end
