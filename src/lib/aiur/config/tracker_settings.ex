defmodule Aiur.Config.TrackerSettings do
  @moduledoc false

  alias Aiur.Workflow

  @spec tracker_kind() :: String.t() | nil
  def tracker_kind do
    Aiur.Config.settings!().tracker.kind
  end

  @doc "The configured tracker integration branch. Raises when it cannot be resolved safely."
  @spec base_branch() :: String.t()
  @spec base_branch(term()) :: String.t()
  @spec base_branch(term(), keyword()) :: String.t()
  def base_branch(source \\ Aiur.Config.settings(), context \\ [])

  def base_branch({:ok, %{tracker: tracker}}, context), do: base_branch(tracker, context)

  def base_branch({:error, reason}, context) do
    raise_unresolved_base_branch({:config_error, reason}, context)
  end

  def base_branch(opts, context) when is_list(opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, branch} -> require_base_branch(branch, context)
      :error -> base_branch(Aiur.Config.settings(), context)
    end
  end

  def base_branch(%{tracker: tracker}, context), do: base_branch(tracker, context)
  def base_branch(%{"tracker" => tracker}, context), do: base_branch(tracker, context)
  def base_branch(%{base_branch: branch}, context), do: require_base_branch(branch, context)
  def base_branch(%{"base_branch" => branch}, context), do: require_base_branch(branch, context)
  def base_branch(%{}, context), do: raise_unresolved_base_branch(:missing, context)
  def base_branch(source, context), do: raise_unresolved_base_branch({:invalid_source, source}, context)

  defp require_base_branch(branch, context) when is_binary(branch) and byte_size(branch) > 0 do
    case String.trim(branch) do
      "" -> raise_unresolved_base_branch(:empty, context)
      trimmed -> trimmed
    end
  end

  defp require_base_branch(branch, context), do: raise_unresolved_base_branch({:invalid, branch}, context)

  defp raise_unresolved_base_branch(reason, context) do
    cwd = context |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()

    config_path =
      context
      |> Keyword.get_lazy(:config_path, &Workflow.workflow_file_path/0)
      |> Path.expand(cwd)

    raise ArgumentError,
          "tracker.base_branch could not be resolved; config path searched: #{config_path}; " <>
            "resolved working directory: #{cwd}; reason: #{inspect(reason)}"
  end

  @spec active_states() :: [String.t()]
  def active_states do
    Aiur.Config.settings!().tracker.active_states
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    Aiur.Config.settings!().tracker.terminal_states
  end

  @doc """
  How long a terminal tracker observation stays lifecycle-fenced while a queued
  authoritative item is undelivered before the daemon finalizes the running
  entry. Defaults to 30 seconds; raise it when provider turn-delivery latency is
  longer (a queued authoritative input that lands after the grace expires is
  dropped at teardown).
  """
  @spec terminal_fence_grace_seconds() :: pos_integer()
  def terminal_fence_grace_seconds do
    Aiur.Config.settings!().tracker.terminal_fence_grace_seconds
  end

  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds do
    Aiur.Config.settings!().polling.interval_seconds
  end

  @doc """
  Per-class poll cadences from `polling.intervals`, in seconds, keyed by poll
  class atom. `%{}` when the operator set none, in which case every class falls
  back to `poll_interval_seconds/0`. A value of `0` means the class is
  on-demand (no timer, #2309). See `Aiur.PollCadence`.
  """
  @spec poll_intervals() :: %{required(atom()) => non_neg_integer()}
  def poll_intervals do
    Aiur.Config.settings!().polling.intervals
    |> Enum.reduce(%{}, fn {class, seconds}, acc when is_binary(class) ->
      Map.put(acc, String.to_existing_atom(class), seconds)
    end)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  How often the single view-state reconciliation sweep runs.

  A recovery bound for lost webhook deliveries, not a freshness knob. See
  `Aiur.GitHub.ViewStateSweep`. The two view-only sources it sweeps
  (`OpenTicketSource`, `AdHocSource`) are reconciled only while a LiveView is
  watching them, so with no dashboard session open the sweep refreshes neither;
  `PackStatus` stays reconciled on every tick regardless of viewers.
  """
  @spec view_state_sweep_seconds() :: pos_integer()
  def view_state_sweep_seconds do
    Aiur.Config.settings!().polling.view_state_sweep_seconds
  end

  @spec events_block_state_debounce_seconds() :: non_neg_integer()
  def events_block_state_debounce_seconds do
    Aiur.Config.settings!().events.block_state_debounce_seconds
  end

  @spec events_custom_events_per_turn_max() :: pos_integer()
  def events_custom_events_per_turn_max do
    Aiur.Config.settings!().events.custom_events_per_turn_max
  end

  @spec events_codeowners_refresh_seconds() :: pos_integer()
  def events_codeowners_refresh_seconds do
    Aiur.Config.settings!().events.codeowners_refresh_seconds
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    Aiur.Config.settings!().workspace.root
  end

  @doc "Optional Docker image used to seed warm build artifacts into workspaces."
  @spec workspace_bootstrap_image() :: String.t() | nil
  def workspace_bootstrap_image do
    Aiur.Config.settings!().workspace.bootstrap_image
  end

  @doc "Whether aiur should pull the configured workspace bootstrap image before seeding."
  @spec workspace_bootstrap_image_pull?() :: boolean()
  def workspace_bootstrap_image_pull? do
    Aiur.Config.settings!().workspace.bootstrap_image_pull
  end

  @spec max_vertical_panes() :: pos_integer()
  def max_vertical_panes do
    Aiur.Config.settings!().max_vertical_panes
  end

  @spec max_log_history_mb() :: pos_integer()
  def max_log_history_mb do
    Aiur.Config.settings!().max_log_history_mb
  end

  @spec workspace_hooks() :: map()
  def workspace_hooks do
    hooks = Aiur.Config.settings!().hooks

    %{
      after_create: hooks.after_create,
      before_run: hooks.before_run,
      after_run: hooks.after_run,
      before_remove: hooks.before_remove,
      timeout_ms: hooks.timeout_ms
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    Aiur.Config.settings!().hooks.timeout_ms
  end
end
