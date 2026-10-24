defmodule Aiur.Instance.RepositoryLeader do
  @moduledoc "Elects one live instance to supervise repository-wide services."
  use GenServer

  require Logger

  alias Aiur.Instance.LeaseStore

  @ttl_ms 30_000
  @renew_interval_ms 10_000

  @spec status(DateTime.t()) :: %{leader: String.t(), lease_age: String.t()}
  def status(now \\ DateTime.utc_now()) do
    case LeaseStore.leader(Aiur.GitHub.Config.repo()) do
      %{instance_id: id, heartbeat_at: %DateTime{} = heartbeat_at} ->
        %{leader: id, lease_age: "#{max(DateTime.diff(now, heartbeat_at, :second), 0)}s"}

      :unheld ->
        %{leader: "none", lease_age: "unknown"}

      :disabled ->
        %{leader: "unconfigured", lease_age: "unknown"}

      _ ->
        %{leader: "unknown", lease_age: "unknown"}
    end
  rescue
    _ -> %{leader: "unknown", lease_age: "unknown"}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      role: Keyword.get(opts, :role, Aiur.Config.instance_role()),
      repository: Keyword.get(opts, :repository, Aiur.GitHub.Config.repo()),
      services: Keyword.get(opts, :services, []),
      supervisor: Keyword.get(opts, :supervisor, Aiur.Instance.GlobalServices),
      ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
      interval_ms: Keyword.get(opts, :interval_ms, @renew_interval_ms),
      store_configured_fun: Keyword.get(opts, :store_configured_fun, &LeaseStore.configured?/0),
      claim_fun: Keyword.get(opts, :claim_fun, &LeaseStore.claim_leader/2),
      renew_fun: Keyword.get(opts, :renew_fun, &LeaseStore.renew_leader/2),
      owns?: false
    }

    send(self(), :elect)
    {:ok, state}
  end

  @impl true
  def handle_info(:elect, state) do
    state = elect(state)
    Process.send_after(self(), :elect, state.interval_ms)
    {:noreply, state}
  end

  defp elect(%{role: "secondary"} = state), do: stop_services(state)

  defp elect(state) do
    if state.store_configured_fun.() do
      renew_or_claim(state)
    else
      start_services(state)
    end
  end

  defp renew_or_claim(%{owns?: true} = state) do
    case state.renew_fun.(state.repository, ttl_ms: state.ttl_ms) do
      :ok -> state
      _ -> state |> stop_services() |> claim_and_start()
    end
  end

  defp renew_or_claim(state), do: claim_and_start(state)

  defp claim_and_start(state) do
    case state.claim_fun.(state.repository, ttl_ms: state.ttl_ms) do
      :acquired -> start_services(state)
      _ -> stop_services(state)
    end
  end

  defp start_services(%{owns?: true} = state), do: state

  defp start_services(state) do
    if Enum.all?(state.services, &start_service(state.supervisor, &1)) do
      %{state | owns?: true}
    else
      stop_services(state)
    end
  end

  defp start_service(supervisor, child) do
    case DynamicSupervisor.start_child(supervisor, child) do
      {:ok, _pid} ->
        true

      {:error, {:already_started, _pid}} ->
        true

      {:error, reason} ->
        Logger.error("repository leader service failed to start: #{inspect(reason)}")
        false
    end
  rescue
    error ->
      Logger.error("repository leader service failed to start: #{Exception.message(error)}")
      false
  end

  defp stop_services(state) do
    if Process.whereis(state.supervisor) do
      state.supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_id, pid, _type, _modules} ->
        DynamicSupervisor.terminate_child(state.supervisor, pid)
      end)
    end

    %{state | owns?: false}
  catch
    :exit, _ -> %{state | owns?: false}
  end
end
