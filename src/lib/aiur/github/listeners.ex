defmodule Aiur.GitHub.Listeners do
  @moduledoc "Supervisor and public facade for GitHub poll-source listeners."
  use Supervisor

  alias Aiur.GitHub.Listeners.{CommandScan, Comments, Firehose}

  @type outcome :: %{connectivity: [{atom(), :ok | {:error, term()}}], poll_interval: pos_integer() | nil}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # Each listener restarts alone; the orchestrator addresses it by name, so nothing above needs to restart.
  @impl true
  def init(_opts), do: Supervisor.init([{Firehose, name: Firehose}, {Comments, name: Comments}, {CommandScan, name: CommandScan}], strategy: :one_for_one)

  @spec poll_firehose(keyword()) :: outcome() | {:error, :firehose_reset | {:tracker_task_exit, term()}}
  def poll_firehose(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, Firehose), {:poll, opts}, :infinity)

  @type comment_input :: Comments.Input.t()

  @spec comment_input(map()) :: comment_input()
  def comment_input(attrs) do
    attrs = Map.update!(attrs, :running_targets, &Comments.TargetSelection.normalize_comment_targets/1)
    struct!(Comments.Input, attrs)
  end

  @spec start_comment_poll(Comments.Input.t(), keyword()) :: :ok
  def start_comment_poll(input, opts \\ []), do: GenServer.cast(Keyword.get(opts, :server, Comments), {:start, input, opts})

  @spec reconcile_hint(map(), Comments.Input.t(), keyword()) :: :ok
  def reconcile_hint(hint, input, opts \\ []), do: GenServer.cast(Keyword.get(opts, :server, Comments), {:reconcile, hint, input, opts})

  @spec update_backoff(non_neg_integer() | nil, keyword()) :: :ok
  def update_backoff(delay, opts \\ []), do: GenServer.cast(Keyword.get(opts, :server, Comments), {:backoff, delay, Keyword.get(opts, :completion), Keyword.get(opts, :poll_opts)})

  @spec scan_commands(keyword()) :: :ok | {:error, term()}
  def scan_commands(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, CommandScan), {:poll, opts}, :infinity)

  @spec reset() :: :ok
  def reset do
    for {_id, pid, _type, _modules} <- Supervisor.which_children(__MODULE__), is_pid(pid), do: GenServer.call(pid, :reset, :infinity)
    :ok
  end
end
