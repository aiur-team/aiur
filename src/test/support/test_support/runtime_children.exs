defmodule Aiur.TestSupport.RuntimeChildren do
  alias Aiur.GitHub.ResourceStore, as: GitHubResourceStore
  alias Aiur.TestSupport.OrchestratorChild

  @doc """
  Restores the shared application children that ordinary tests rely on after a
  sibling intentionally stopped one for an unavailable-service case.
  """
  def ensure_runtime_children_running do
    with :ok <- ensure_aiur_supervisor_running(),
         :ok <- ensure_pubsub_running(),
         :ok <- ensure_id_generator_running(),
         :ok <- ensure_provider_meter_store_running(),
         :ok <- ensure_subscription_store_supervisor_running(),
         :ok <- ensure_branch_ref_store_running(),
         :ok <- ensure_workflow_store_running(),
         :ok <- ensure_read_cache_running() do
      ensure_resource_store_running()
    end
  end

  @doc """
  Restarts the shared `Aiur.Orchestrator` when a prior test terminated it and
  its own restart never ran or failed. One such leak otherwise fails every
  later case in the partition that reads the live orchestrator (#4888).
  """
  @spec ensure_orchestrator_running() :: :ok | :error
  def ensure_orchestrator_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Orchestrator) do
      pid when is_pid(pid) -> :ok
      nil -> restart_orchestrator()
    end
  end

  # Any restart outcome (started, raced, failed init) is judged by the name.
  defp restart_orchestrator do
    case OrchestratorChild.supervised_pid() do
      # A test swapped the name out and never gave it back; restart_child would answer {:error, :running}.
      pid when is_pid(pid) -> reregister_orchestrator(pid)
      nil -> restart_orchestrator_child()
    end

    if Process.whereis(Aiur.Orchestrator), do: :ok, else: :error
  end

  defp reregister_orchestrator(pid) do
    Process.register(pid, Aiur.Orchestrator)
  rescue
    ArgumentError -> :raced
  end

  defp restart_orchestrator_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.Orchestrator)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  @doc "Ensures the shared durable event ID generator is running after an application restart."
  @spec ensure_id_generator_running() :: :ok | :error
  def ensure_id_generator_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Events.IdGenerator) do
      pid when is_pid(pid) -> :ok
      nil -> restart_id_generator()
    end
  end

  @doc "Ensures the shared provider meter store is running after an application restart."
  @spec ensure_provider_meter_store_running() :: :ok | :error
  def ensure_provider_meter_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.ProviderMeters.Store) do
      pid when is_pid(pid) -> :ok
      nil -> restart_provider_meter_store()
    end
  end

  @doc """
  Ensures the shared `Aiur.Events.BranchRefStore` singleton is running after a
  sibling test tears down or restarts the application supervisor.
  """
  @spec ensure_branch_ref_store_running() :: :ok | :error
  def ensure_branch_ref_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Events.BranchRefStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_branch_ref_store()
    end
  end

  @doc """
  Ensures the shared GitHub resource store is running before a test resets or
  seeds it. A stopped store deliberately makes writes no-ops, so merely calling
  `ResourceStore.reset/0` cannot distinguish an empty store from a missing one.
  """
  @spec ensure_resource_store_running() :: :ok | :error
  def ensure_resource_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(GitHubResourceStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_resource_store()
    end
  end

  @doc """
  Ensures the shared `Aiur.WorkflowStore` singleton is running, restarting the
  supervised child when a prior test terminated it and left it down. Tolerates
  restart races (already-started / already-present / restarting / not-found) by
  re-checking the registered name. Best-effort: returns `:ok` when the store is
  up, `:error` only if it could not be brought back.
  """
  def ensure_workflow_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.WorkflowStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_workflow_store()
    end
  end

  @doc """
  Ensures the shared `Aiur.PubSub` registry is running, restarting the
  supervised `Phoenix.PubSub.Supervisor` child when a prior test terminated it
  (or the application supervisor toppled while a sibling was unavailable).
  Tests that subscribe to `Aiur.PubSub` must call this before subscribing —
  the registry is a shared app child that a sibling can stop, and subscribing
  to a missing registry raises `ArgumentError: unknown registry: Aiur.PubSub`
  rather than failing silently (#2397). Prefer this over `start_supervised!`-ing
  a replacement `Phoenix.PubSub` under the ExUnit supervisor: a temporary
  replacement dies at module end and can leave the shared name permanently
  unregistered for every later test in the suite. Signal-based (`Process.whereis`)
  — never a duration.
  """
  @spec ensure_pubsub_running() :: :ok | {:error, term()}
  def ensure_pubsub_running(retries \\ 1) do
    case Process.whereis(Aiur.PubSub) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_pubsub_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_pubsub_running(retries - 1)

          failure ->
            pubsub_status(failure)
        end
    end
  end

  @doc """
  Ensures the shared `Aiur.Events.SubscriptionStoreSupervisor` is running
  before a test attaches a per-issue subscription store. A missing dynamic
  supervisor makes `SubscriptionStore.attach/1` exit with `:noproc` (#2397).
  Signal-based (`Process.whereis`) — never a duration.
  """
  @spec ensure_subscription_store_supervisor_running() :: :ok | :error
  def ensure_subscription_store_supervisor_running(retries \\ 1) do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Events.SubscriptionStoreSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_subscription_store_supervisor_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_subscription_store_supervisor_running(retries - 1)

          _ ->
            subscription_store_supervisor_status()
        end
    end
  end

  @doc """
  Ensures the shared `Aiur.GitHub.ReadCache` is running before a test reads or
  resets it. A stopped cache makes `ReadCache.snapshot/0` answer `available?:
  false` with no entries, which under load reads as a hard cache miss on every
  request (#2397). Signal-based (`Process.whereis`) — never a duration.
  """
  @spec ensure_read_cache_running() :: :ok | :error
  def ensure_read_cache_running(retries \\ 1) do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.GitHub.ReadCache) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_read_cache_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_read_cache_running(retries - 1)

          _ ->
            read_cache_status()
        end
    end
  end

  defp read_cache_status do
    if Process.whereis(Aiur.GitHub.ReadCache), do: :ok, else: :error
  end

  # Name the failure: a bare `:error` in a setup assert hid that the root
  # supervisor itself was gone or still shutting down (#4527).
  defp pubsub_status(failure) do
    case Process.whereis(Aiur.PubSub) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        supervisor = Process.whereis(Aiur.Supervisor)

        {:error, {:pubsub_not_running, restart: failure, aiur_supervisor: supervisor, supervisor_accepting_calls?: supervisor_accepting_calls?(supervisor, 1_000)}}
    end
  end

  defp subscription_store_supervisor_status do
    case Process.whereis(Aiur.Events.SubscriptionStoreSupervisor) do
      pid when is_pid(pid) -> :ok
      nil -> :error
    end
  end

  defp restart_workflow_store(retries \\ 1) do
    case restart_workflow_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      # The application supervisor can terminate after the initial
      # `Process.whereis/1` check and before the synchronous restart call.
      # Bring it back and retry the child once so a suite sibling cannot leak
      # that narrow shutdown race into an unrelated test setup.
      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_workflow_store(retries - 1)

      :supervisor_unavailable ->
        :error

      # A restart can race a sibling (already-present / running / restarting) or
      # genuinely fail — `WorkflowStore.init/1` reads the workflow file and stops
      # with `{:missing_workflow_file, ...}` when a test transiently pointed the
      # config path at a missing file. A single catch-all keeps both cases from
      # raising a CaseClauseError (`restart_orchestrator/0` can `flunk` on the
      # race because `ExUnit.Assertions` isn't imported into this plain module);
      # fall back to the registered name: `:ok` if up, `:error` if still down.
      {:error, _reason} ->
        if Process.whereis(Aiur.WorkflowStore), do: :ok, else: :error
    end
  end

  defp restart_branch_ref_store(retries \\ 1) do
    case restart_branch_ref_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_branch_ref_store(retries - 1)

      :supervisor_unavailable ->
        :error

      {:error, _reason} ->
        if Process.whereis(Aiur.Events.BranchRefStore), do: :ok, else: :error
    end
  end

  defp restart_workflow_store_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.WorkflowStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_branch_ref_store_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.BranchRefStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_resource_store(retries \\ 1) do
    case restart_resource_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_resource_store(retries - 1)

      :supervisor_unavailable ->
        :error

      {:error, _reason} ->
        if Process.whereis(GitHubResourceStore), do: :ok, else: :error
    end
  end

  defp restart_resource_store_child do
    Supervisor.restart_child(Aiur.Supervisor, GitHubResourceStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_pubsub_child do
    Supervisor.restart_child(Aiur.Supervisor, Phoenix.PubSub.Supervisor)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_id_generator do
    case Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.IdGenerator) do
      {:ok, pid} when is_pid(pid) -> :ok
      {:error, {:already_started, pid}} when is_pid(pid) -> :ok
      _ -> if Process.whereis(Aiur.Events.IdGenerator), do: :ok, else: :error
    end
  catch
    :exit, _reason -> :error
  end

  defp restart_provider_meter_store do
    case Supervisor.restart_child(Aiur.Supervisor, Aiur.ProviderMeters.Store) do
      {:ok, pid} when is_pid(pid) -> :ok
      {:error, {:already_started, pid}} when is_pid(pid) -> :ok
      _ -> if Process.whereis(Aiur.ProviderMeters.Store), do: :ok, else: :error
    end
  catch
    :exit, _reason -> :error
  end

  defp restart_subscription_store_supervisor_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreSupervisor)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_read_cache_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.GitHub.ReadCache)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  @doc """
  Ensures the dashboard's financial-data tree is running. Stream Deck token
  issuance fails closed with `:authentication_required` while
  `AiurWeb.FinancialDataAccess.Generation` is absent, so a sibling that toppled
  `Aiur.Supervisor` or stopped this child would otherwise fail every later
  Stream Deck test (#4695).
  """
  @spec ensure_financial_data_running() :: :ok | :error
  def ensure_financial_data_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(AiurWeb.FinancialDataAccess.Generation) do
      pid when is_pid(pid) -> :ok
      nil -> restart_financial_data()
    end
  end

  defp restart_financial_data do
    case Supervisor.restart_child(Aiur.Supervisor, AiurWeb.FinancialData.Supervisor) do
      {:ok, _pid} -> :ok
      _ -> if Process.whereis(AiurWeb.FinancialDataAccess.Generation), do: :ok, else: :error
    end
  catch
    :exit, _reason -> :error
  end

  def ensure_aiur_supervisor_running do
    case Process.whereis(Aiur.Supervisor) do
      pid when is_pid(pid) ->
        registered_supervisor_status(pid, &restart_aiur_application/0)

      nil ->
        restart_aiur_application()
    end
  end

  defp restart_aiur_application do
    ensure_aiur_application_started(&verify_or_restart_aiur_application/0)
  end

  defp verify_or_restart_aiur_application do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) ->
        registered_supervisor_status(supervisor, &stop_and_start_aiur_application/0)

      nil ->
        stop_and_start_aiur_application()
    end
  end

  defp registered_supervisor_status(supervisor, recovery) do
    if supervisor_accepting_calls?(supervisor),
      do: :ok,
      else: recover_stopped_supervisor(supervisor, recovery)
  end

  def recover_stopped_supervisor(supervisor, recovery) do
    with :ok <- await_process_down(supervisor), do: recovery.()
  end

  defp stop_and_start_aiur_application do
    case Application.stop(:aiur) do
      :ok -> start_aiur_application()
      {:error, {:not_started, :aiur}} -> start_aiur_application()
      {:error, _reason} -> :error
    end
  end

  defp start_aiur_application do
    ensure_aiur_application_started(&aiur_supervisor_status/0)
  end

  defp ensure_aiur_application_started(on_started) do
    case Application.ensure_all_started(:aiur) do
      {:ok, _apps} -> on_started.()
      {:error, {:already_started, _app}} -> on_started.()
      {:error, {:aiur, {:already_started, _app}}} -> on_started.()
      {:error, _reason} -> :error
    end
  end

  defp aiur_supervisor_status do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) -> if(supervisor_accepting_calls?(supervisor), do: :ok, else: :error)
      nil -> :error
    end
  end

  def supervisor_accepting_calls?(supervisor, timeout \\ :infinity)

  def supervisor_accepting_calls?(nil, _timeout), do: false

  def supervisor_accepting_calls?(supervisor, timeout) do
    # `Supervisor.which_children/1` waits forever; the same call with a bound
    # lets a caller with a deadline report a stuck supervisor.
    GenServer.call(supervisor, :which_children, timeout)
    true
  catch
    :exit, _reason -> false
  end

  @doc false
  @spec await_process_down(pid(), timeout()) :: :ok | :error
  def await_process_down(process, timeout \\ 2_000) when is_pid(process) do
    ref = Process.monitor(process)

    receive do
      {:DOWN, ^ref, :process, ^process, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :error
    end
  end
end
