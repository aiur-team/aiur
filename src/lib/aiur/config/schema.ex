defmodule Aiur.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Github do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:repo, :string)
      field(:label_prefix, :string, default: "agent")
      field(:bot_account, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:repo, :label_prefix, :bot_account], empty_values: [])
    end
  end

  defmodule Linear do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:assignee, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:api_key, :project_slug, :endpoint, :assignee], empty_values: [])
    end
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias Aiur.Config.Schema.{Github, Linear}

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])

      embeds_one(:github, Github, on_replace: :update, defaults_to_struct: true)
      embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:kind, :active_states, :terminal_states], empty_values: [])
      |> cast_embed(:github, with: &Github.changeset/2)
      |> cast_embed(:linear, with: &Linear.changeset/2)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_seconds, :integer, default: 30)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      if Map.has_key?(attrs, "interval_ms") or Map.has_key?(attrs, :interval_ms) do
        raise ArgumentError,
              "polling.interval_ms is no longer supported; rename to interval_seconds " <>
                "(value in seconds, not milliseconds)"
      end

      schema
      |> cast(attrs, [:interval_seconds], empty_values: [])
      |> validate_number(:interval_seconds, greater_than: 0)
    end
  end

  defmodule Events do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:block_state_debounce_seconds, :integer, default: 10)
      field(:custom_events_per_turn_max, :integer, default: 5)
      field(:codeowners_refresh_seconds, :integer, default: 3_600)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:block_state_debounce_seconds, :custom_events_per_turn_max, :codeowners_refresh_seconds],
        empty_values: []
      )
      |> validate_number(:block_state_debounce_seconds, greater_than_or_equal_to: 0)
      |> validate_number(:custom_events_per_turn_max, greater_than: 0)
      |> validate_number(:codeowners_refresh_seconds, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "aiur_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      # codex app-server expects an enum string (untrusted | on-failure |
      # on-request | granular | never); a map crashes the turn. `untrusted`
      # preserves the prior fail-closed default (only `never` auto-approves).
      field(:approval_policy, StringOrMap, default: "untrusted")

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:read_timeout_ms, :integer, default: 5_000)
      # Codex-specific thrash guard (moved out of the shared agent section).
      field(:thrash_max_per_window, :integer, default: 6)
      field(:thrash_window_seconds, :integer, default: 60)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :read_timeout_ms,
          :thrash_max_per_window,
          :thrash_window_seconds
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_length(:command, min: 1)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:thrash_max_per_window, greater_than: 0)
      |> validate_number(:thrash_window_seconds, greater_than: 0)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "aiur-claude")
      field(:model, :string)
      field(:permission_mode, :string, default: "bypassPermissions")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :model, :permission_mode], empty_values: [])
      |> validate_length(:command, min: 1)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias Aiur.Config.Schema
    alias Aiur.Config.Schema.{Claude, Codex}

    @primary_key false
    embedded_schema do
      field(:kind, :string, default: "codex")
      # Setting #2 (RC opt-in), orthogonal to :kind. Only consulted when the
      # resolved backend is RC-capable. This default is the single flip point
      # for always-remote: change `false` here and every dispatch attaches RC.
      field(:remote_control, :boolean, default: false)
      field(:max_concurrent_agents, :integer, default: 10)
      # nil = uncapped (no per-issue turn limit). A YAML value of `none` /
      # `unlimited` (or an absent key) resolves to nil; any present number must
      # be > 0.
      field(:max_turns, :integer)
      field(:max_retry_attempts, :integer, default: 3)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:routing, :map, default: %{})
      field(:complexity_prompts, :map, default: %{})
      # Backend-agnostic turn/stall timeouts (promoted from codex; claude-repl
      # already reads these via Config.agent_turn_timeout_ms/0).
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      # Safety net: hard-kill an agent that has been actively running this
      # many minutes (paused/blocked time excluded). 0 disables.
      field(:max_agent_duration_minutes, :integer, default: 60)
      # Per-scheduler 1-min load ceiling for the dispatch load gate (#465).
      # Enabled by default so high-concurrency runs have protection without
      # extra operator knowledge; explicit YAML null disables it.
      field(:max_load_average, :float, default: 1.5)
      # nil = derive from schedulers_online/4; 0 disables the runtime synthetic
      # load-generator guard; positive integers cap known generators per agent.
      field(:synthetic_load_process_cap, :integer)

      embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
      embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        drop_uncapped_max_turns(attrs),
        [
          :kind,
          :remote_control,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_attempts,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :routing,
          :complexity_prompts,
          :turn_timeout_ms,
          :stall_timeout_ms,
          :max_agent_duration_minutes,
          :max_load_average,
          :synthetic_load_process_cap
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_attempts, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:max_agent_duration_minutes, greater_than_or_equal_to: 0)
      |> validate_number(:max_load_average, greater_than: 0)
      |> validate_number(:synthetic_load_process_cap, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> update_change(:routing, &Schema.normalize_agent_routing/1)
      |> Schema.validate_agent_routing(:routing)
      |> update_change(:complexity_prompts, &Schema.normalize_complexity_prompts/1)
      |> Schema.validate_complexity_prompts(:complexity_prompts)
      |> cast_embed(:claude, with: &Claude.changeset/2)
      |> cast_embed(:codex, with: &Codex.changeset/2)
    end

    # A `max_turns` of `none`/`unlimited`/`""` means uncapped — drop the key so
    # the field stays nil instead of failing integer casting.
    defp drop_uncapped_max_turns(attrs) do
      Enum.reduce([:max_turns, "max_turns"], attrs, &drop_key_if_uncapped/2)
    end

    defp drop_key_if_uncapped(key, attrs) do
      case Map.fetch(attrs, key) do
        {:ok, value} when is_binary(value) ->
          if uncapped_max_turns?(value), do: Map.delete(attrs, key), else: attrs

        _ ->
          attrs
      end
    end

    defp uncapped_max_turns?(value) do
      String.downcase(String.trim(value)) in ["none", "unlimited", ""]
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 600_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Prewarm do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      # base_build is the one-time base build command. It is usually NOT written
      # inline: `base_build_file` points at a sibling script (`.aiur/prewarm`)
      # whose contents `Aiur.Workflow` reads into `base_build`, keeping the
      # multi-line shell out of the main config (mirrors `hooks_file`).
      field(:base_build, :string)
      field(:base_build_file, :string)
      field(:poll_seconds, :integer, default: 0)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :base_build, :base_build_file, :poll_seconds], empty_values: [])
      |> validate_number(:poll_seconds, greater_than_or_equal_to: 0)
    end
  end

  defmodule Alerts do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    embedded_schema do
      # `enabled` defaults true so machines already using `alerts.yaml` +
      # `~/alerts/*.wav` keep playing without an `alerts:` section (the OS-default
      # cross-platform set is the opt-in piece, gated by `use_os_default_sounds`).
      field(:enabled, :boolean, default: true)
      # false → topic→sound mapping from the alerts file (existing behaviour);
      # true → built-in macOS/Linux system sounds keyed by alert category.
      field(:use_os_default_sounds, :boolean, default: false)
      # Optional folder of custom sound files. In mapping mode it resolves bare
      # filenames; in OS-default mode a `<category>.<ext>` file here wins over the
      # OS sound.
      field(:sound_dir, :string)
      # Optional custom topic→sound YAML; defaults to the repo `alerts.yaml`.
      field(:alerts_file, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:enabled, :use_os_default_sounds, :sound_dir, :alerts_file], empty_values: [])
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      # Read-only by default: the dashboard's agent-write paths (operator chat,
      # pause) are disabled until a deliberate dashboard parity pass. Flip to
      # `true` to re-enable them. See issue #371.
      field(:dashboard_writable, :boolean, default: false)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :dashboard_writable, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # 0 = bind a free OS-assigned loopback port. The dashboard must bind so
      # claude remote-control's transcript hook can reach it; without a bound
      # port the hook is skipped and RC runs fail `:no_transcript`. Set an
      # explicit port to expose the dashboard at a fixed address.
      field(:port, :integer, default: 0)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Opencode do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "opencode")
      field(:bridge_port, :integer, default: 4097)
      field(:bridge_host, :string, default: "127.0.0.1")
      field(:serve_args, {:array, :string}, default: [])
      field(:model_prefix, :string, default: "aiur")
      field(:prewarm_disabled, :boolean, default: false)
    end

    @fields [:command, :bridge_port, :bridge_host, :serve_args, :model_prefix, :prewarm_disabled]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:bridge_port, greater_than_or_equal_to: 0, less_than: 65_536)
      |> validate_length(:bridge_host, min: 1)
      |> validate_length(:model_prefix, min: 1)
    end
  end

  embedded_schema do
    field(:max_vertical_panes, :integer, default: 3)
    field(:pre_warmed_sessions, :integer, default: 3)
    field(:max_log_history_mb, :integer, default: 1000)
    field(:prompt_file, :string)
    field(:debug, :boolean, default: false)

    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:opencode, Opencode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:events, Events, on_replace: :update, defaults_to_struct: true)
    embeds_one(:prewarm, Prewarm, on_replace: :update, defaults_to_struct: true)
    embeds_one(:alerts, Alerts, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.agent.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.agent.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_agent_routing(nil | map()) :: map()
  def normalize_agent_routing(nil), do: %{}

  def normalize_agent_routing(routing) when is_map(routing) do
    Enum.reduce(routing, %{}, fn {level, backend}, acc ->
      Map.put(acc, normalize_routing_level(level), to_string(backend))
    end)
  end

  @doc false
  @spec validate_agent_routing(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_agent_routing(changeset, field) do
    known = Aiur.CodingAgent.known_backends()

    validate_change(changeset, field, fn ^field, routing ->
      Enum.flat_map(routing, fn {level, value} ->
        routing_errors(field, known, level, value)
      end)
    end)
  end

  defp routing_errors(field, known, level, value) do
    cond do
      not is_integer(level) or level <= 0 ->
        [{field, "complexity levels must be positive integers"}]

      not is_binary(value) or routing_backend(value) not in known ->
        [{field, "unknown backend #{inspect(value)}; known backends: #{inspect(known)} (optionally backend:model)"}]

      routing_remote_flag?(value) and not Aiur.CodingAgent.remote_control?(routing_backend(value)) ->
        [{field, "+remote routing requires a remote-capable backend, got #{inspect(value)}"}]

      not valid_routing_effort?(value) ->
        invalid_routing_effort_error(field, value)

      true ->
        []
    end
  end

  defp invalid_routing_effort_error(field, value) do
    backend = routing_effort_backend(value)

    [
      {field,
       "invalid effort #{inspect(routing_effort(value))} for backend #{inspect(backend)}; " <>
         "valid efforts: #{inspect(Aiur.CodingAgent.efforts(backend))}"}
    ]
  end

  # A routing value's optional effort segment must be in the backend's valid
  # set. No effort segment is always fine (the backend's own default applies).
  # The backend is already known here (an earlier cond branch rejects unknown
  # backends), so `efforts/1` returns its real set. `claude+remote` dispatches
  # through the interactive REPL transport, so validate its effort against that
  # transport rather than the headless app-server wrapper.
  defp valid_routing_effort?(value) do
    case routing_effort(value) do
      nil -> true
      effort -> effort in Aiur.CodingAgent.efforts(routing_effort_backend(value))
    end
  end

  defp routing_effort_backend(value) do
    case {routing_backend(value), routing_remote_flag?(value)} do
      {"claude", true} -> "claude-repl"
      {backend, _remote?} -> backend
    end
  end

  @doc """
  Splits a routing value into its backend and optional model. A routing
  value is `"<backend>"`, `"<backend>:<model>"` (e.g. `"claude:sonnet"`), or
  `"<backend>:<model>:<effort>"` (e.g. `"codex:gpt-5.5:high"`), optionally
  with a trailing `+remote` flag (`"claude:haiku+remote"`) that is stripped
  here and surfaced separately by `routing_remote_flag?/1`. The optional
  trailing effort segment is dropped here and surfaced by `routing_effort/1`;
  an effort-only value omits the model (`"codex::high"`).
  """
  @spec split_routing_value(String.t()) :: {String.t(), String.t() | nil}
  def split_routing_value(value) when is_binary(value) do
    case value |> strip_remote_flag() |> String.split(":", parts: 3) do
      [backend, model | _] when model != "" -> {backend, model}
      [backend | _] -> {backend, nil}
    end
  end

  @doc """
  The optional per-complexity effort carried by a routing value's third
  `:`-separated segment (`"<backend>:<model>:<effort>"` or the model-less
  `"<backend>::<effort>"`), or `nil` when no effort is pinned. The valid
  set is backend-aware (see `Aiur.CodingAgent.efforts/1`) and enforced by
  `validate_agent_routing/2`.
  """
  @spec routing_effort(String.t()) :: String.t() | nil
  def routing_effort(value) when is_binary(value) do
    case value |> strip_remote_flag() |> String.split(":", parts: 3) do
      [_backend, _model, effort] when effort != "" -> effort
      _ -> nil
    end
  end

  @doc "Whether a routing value carries the optional trailing `+remote` flag."
  @spec routing_remote_flag?(String.t()) :: boolean()
  def routing_remote_flag?(value) when is_binary(value), do: String.ends_with?(value, "+remote")

  defp strip_remote_flag(value), do: String.replace_suffix(value, "+remote", "")

  defp routing_backend(value) when is_binary(value), do: value |> split_routing_value() |> elem(0)
  defp routing_backend(_value), do: nil

  @doc false
  @spec normalize_complexity_prompts(nil | map()) :: map()
  def normalize_complexity_prompts(nil), do: %{}

  def normalize_complexity_prompts(prompts) when is_map(prompts) do
    Enum.reduce(prompts, %{}, fn {level, text}, acc ->
      Map.put(acc, normalize_routing_level(level), text)
    end)
  end

  @doc false
  @spec validate_complexity_prompts(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_complexity_prompts(changeset, field) do
    validate_change(changeset, field, fn ^field, prompts ->
      Enum.flat_map(prompts, fn {level, text} ->
        cond do
          not is_integer(level) or level <= 0 ->
            [{field, "complexity levels must be positive integers"}]

          not is_binary(text) ->
            [{field, "complexity prompt values must be strings"}]

          true ->
            []
        end
      end)
    end)
  end

  defp normalize_routing_level(level) when is_integer(level), do: level

  defp normalize_routing_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} -> n
      _ -> level
    end
  end

  defp normalize_routing_level(level), do: level

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(
      attrs,
      [:max_vertical_panes, :pre_warmed_sessions, :max_log_history_mb, :prompt_file, :debug],
      empty_values: []
    )
    |> validate_number(:max_vertical_panes, greater_than: 0)
    |> validate_number(:pre_warmed_sessions, greater_than_or_equal_to: 0)
    |> validate_number(:max_log_history_mb, greater_than: 0)
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:opencode, with: &Opencode.changeset/2)
    |> cast_embed(:events, with: &Events.changeset/2)
    |> cast_embed(:prewarm, with: &Prewarm.changeset/2)
    |> cast_embed(:alerts, with: &Alerts.changeset/2)
  end

  defp finalize_settings(settings) do
    linear = %{
      settings.tracker.linear
      | api_key: resolve_secret_setting(settings.tracker.linear.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.linear.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    tracker = %{settings.tracker | linear: linear}

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "aiur_workspaces"))
    }

    codex = %{
      settings.agent.codex
      | approval_policy: normalize_keys(settings.agent.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.agent.codex.turn_sandbox_policy)
    }

    agent = %{settings.agent | codex: codex}

    %{settings | tracker: tracker, workspace: workspace, agent: agent}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value), do: drop_nil_values(value, [])

  defp drop_nil_values(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      child_path = path ++ [key]

      case drop_nil_values(nested, child_path) do
        nil ->
          put_preserved_nil(acc, key, child_path)

        normalized ->
          Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value, path) when is_list(value), do: Enum.map(value, &drop_nil_values(&1, path))
  defp drop_nil_values(value, _path), do: value

  defp put_preserved_nil(acc, key, path) do
    if preserve_nil_path?(path), do: Map.put(acc, key, nil), else: acc
  end

  # max_load_average defaults to 1.5 (gate on), so an explicit YAML null is the
  # only way to disable the gate. Without this, drop_nil_values/2 would strip the
  # null before the changeset, letting the default silently re-enable the gate.
  # Keep this path aligned with the Agent schema field's location.
  defp preserve_nil_path?(["agent", "max_load_average"]), do: true
  defp preserve_nil_path?(_path), do: false

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "aiur_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
