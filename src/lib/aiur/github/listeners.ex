defmodule Aiur.GitHub.Listeners do
  @moduledoc "Supervisor and public facade for GitHub poll-source listeners."
  use Supervisor

  alias Aiur.GitHub.Listeners.Firehose

  @type outcome :: %{connectivity: [{atom(), :ok | {:error, term()}}], poll_interval: pos_integer() | nil}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([{Firehose, name: Firehose}], strategy: :one_for_one)

  @spec poll_firehose(keyword()) :: outcome() | {:error, :firehose_reset | {:tracker_task_exit, term()}}
  def poll_firehose(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, Firehose), {:poll, opts}, :infinity)

  @spec reset() :: :ok
  def reset do
    for {_id, pid, _type, _modules} <- Supervisor.which_children(__MODULE__), is_pid(pid), do: GenServer.call(pid, :reset, :infinity)
    :ok
  end
end
