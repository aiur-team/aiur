defmodule Aiur.BuildOrder.PackStatus do
  @moduledoc """
  Supervised writer for the daemon-owned `status.json` projection beside every
  discovered Build Order pack.

  The planning contract makes a promoted ticket's tracker state authoritative
  and names `status.json` the daemon-owned runtime projection. Until this
  poller existed nothing wrote that file: member completion was readable only
  from `Aiur.CurrentRunMembership`, which is scoped to the *current* run and is
  rebuilt from an empty journal whenever a new run starts. A Build Order that
  spans more than one run therefore lost every completed member on the run
  boundary and rendered 0% for work that was already merged.

  Each cycle reads the promoted ticket numbers out of each pack manifest,
  deduplicates them per repository, and resolves their tracker state in batches
  of 50 within the configured cycle-wide planning-call budget. The result is
  merged into `status.json`; unrelated keys in that file (`state`,
  `completed_at`, operator annotations) are preserved. A failed, partial, or
  budget-exhausted fetch leaves the affected projection untouched — a stale
  completion fact is strictly better than silently reverting a merged ticket
  to 0%. When demand exceeds one cycle's budget, later cycles rotate the first
  repository and member chunk so later demand also receives capacity.
  """

  use GenServer

  require Logger

  alias Aiur.BuildOrder.{Lifecycle, PackPaths, ProviderHealth}
  alias Aiur.Fs
  alias Aiur.GitHub.{Config, Transport}

  @default_interval :timer.minutes(5)
  @chunk_size 50
  @topic "build-order-pack-status:changed"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Requests an out-of-band reconcile (async)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc "Synchronously reconciles and returns the written pack paths (test/support)."
  @spec refresh_sync(GenServer.server()) :: {:ok, [Path.t()]} | {:error, term()}
  def refresh_sync(server \\ __MODULE__), do: GenServer.call(server, :refresh_sync, 30_000)

  @doc "Returns the freshness and health of the tracker-backed status projection."
  @spec health(GenServer.server()) :: ProviderHealth.t()
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  catch
    :exit, _reason -> unavailable_health()
  end

  @doc "Subscribes the caller to status-projection health and generation changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      inflight: nil,
      interval: Keyword.get(opts, :poll_interval, @default_interval),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      paths_fun: Keyword.get(opts, :paths_fun, &PackPaths.tracked_planning/0),
      planning_call_budget: Keyword.get_lazy(opts, :planning_call_budget, &Config.planning_call_budget/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      health: unavailable_health(System.unique_integer([:positive, :monotonic]))
    }

    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh_sync, _from, %{inflight: ref} = state) when is_reference(ref) do
    {:reply, {:error, :refresh_in_progress}, state}
  end

  def handle_call(:refresh_sync, _from, state) do
    result = reconcile(state)
    {:reply, public_result(result), record_result(state, result)}
  end

  def handle_call(:health, _from, state) do
    {:reply, %{state.health | refreshing?: is_reference(state.inflight)}, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, ensure_reconcile(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> ensure_reconcile() |> schedule_next()}

  def handle_info({ref, result}, %{inflight: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> record_result(result) |> Map.put(:inflight, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{inflight: ref} = state) do
    {:noreply, state |> record_result({:error, {:task_exit, reason}}) |> Map.put(:inflight, nil)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_reconcile(%{inflight: ref} = state) when is_reference(ref), do: state

  defp ensure_reconcile(state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> reconcile(state) end)
    %{state | inflight: task.ref}
  end

  defp schedule_next(state) do
    Process.send_after(self(), :poll, state.interval)
    state
  end

  defp record_result(state, result) do
    attempted_at = state.now_fun.()
    previous = state.health

    {health, publish?} =
      case result do
        {:ok, _paths, changed?} ->
          {successful_health(previous, attempted_at, changed?), changed? or previous.state != :healthy}

        {:error, reason, changed?} ->
          {failed_health(previous, attempted_at, changed?, failure(reason)), true}

        {:error, reason} ->
          {failed_health(previous, attempted_at, false, failure(reason)), true}
      end

    if publish?, do: broadcast_changed(health)
    %{state | health: health}
  end

  defp successful_health(previous, attempted_at, changed?) do
    generation =
      if changed? or not (is_integer(previous.generation) and previous.generation > 0),
        do: next_generation(previous.generation),
        else: previous.generation

    ProviderHealth.new(generation, :healthy, true,
      observed_at: attempted_at,
      last_success_at: attempted_at,
      last_attempt_at: attempted_at
    )
  end

  defp failed_health(previous, attempted_at, changed?, failure) do
    generation = if changed?, do: next_generation(previous.generation), else: previous.generation

    ProviderHealth.new(generation, failed_state(previous), false,
      observed_at: previous.last_success_at,
      last_success_at: previous.last_success_at,
      last_attempt_at: attempted_at,
      failure: failure,
      retry_count: previous.retry_count + 1
    )
  end

  defp next_generation(_generation), do: System.unique_integer([:positive, :monotonic])

  defp failed_state(%ProviderHealth{last_success_at: %DateTime{}}), do: :stale
  defp failed_state(_health), do: :unavailable

  defp unavailable_health(generation \\ :unknown) do
    ProviderHealth.new(generation, :unavailable, false, failure: :pack_status_unavailable)
  end

  defp failure({:pack_refresh_failed, errors}) when is_list(errors) do
    if :planning_call_budget_exhausted in errors,
      do: :planning_call_budget_exhausted,
      else: :pack_status_refresh_failed
  end

  defp failure(:planning_call_budget_exhausted), do: :planning_call_budget_exhausted
  defp failure(_reason), do: :pack_status_refresh_failed

  defp broadcast_changed(health) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_order_pack_status_changed, health})
    end

    :ok
  end

  # --- reconcile --------------------------------------------------------------

  @spec reconcile(map()) :: {:ok, [Path.t()], boolean()} | {:error, term(), boolean()}
  defp reconcile(state) do
    case state.token_fun.() do
      {:ok, token} ->
        state.paths_fun.()
        |> reconcile_packs(token, state)
        |> reconcile_result()

      {:error, reason} ->
        {:error, reason, false}

      _other ->
        {:error, :unavailable, false}
    end
  rescue
    error -> {:error, error, false}
  catch
    kind, reason -> {:error, {kind, reason}, false}
  end

  defp reconcile_packs(paths, token, state) do
    facts =
      Enum.map(paths, fn pack_path ->
        case pack_facts(pack_path) do
          {:ok, repository, numbers} -> {:ok, %{path: pack_path, repository: repository, numbers: numbers}}
          error -> {:error, {pack_path, error}}
        end
      end)

    fetched = fetch_repositories(facts, token, state)

    Enum.map(facts, fn
      {:ok, fact} -> reconcile_fact(fact, Map.fetch!(fetched, fact.repository), state)
      {:error, _reason} = error -> error
    end)
  end

  defp fetch_repositories(facts, token, state) do
    facts
    |> Enum.flat_map(fn
      {:ok, fact} -> [fact]
      {:error, _reason} -> []
    end)
    |> Enum.group_by(& &1.repository)
    |> Enum.sort_by(fn {repository, _facts} -> repository end)
    |> rotate(state.health.retry_count)
    |> Enum.reduce({%{}, state.planning_call_budget}, fn
      {repository, _repository_facts}, {fetched, 0} ->
        {Map.put(fetched, repository, %{lifecycles: %{}, error: :planning_call_budget_exhausted}), 0}

      {repository, repository_facts}, {fetched, budget} ->
        numbers =
          repository_facts
          |> Enum.flat_map(& &1.numbers)
          |> Enum.uniq()
          |> Enum.sort()
          |> rotate(state.health.retry_count * state.planning_call_budget * @chunk_size)

        {result, remaining_budget} = fetch_repository(numbers, repository, token, state, budget)
        {Map.put(fetched, repository, result), remaining_budget}
    end)
    |> elem(0)
  end

  defp fetch_repository(numbers, repository, token, state, budget) do
    numbers
    |> Stream.chunk_every(@chunk_size)
    |> Enum.reduce_while({%{lifecycles: %{}, error: nil}, budget}, fn
      _chunk, {result, 0} ->
        {:halt, {%{result | error: :planning_call_budget_exhausted}, 0}}

      chunk, {result, remaining_budget} ->
        case fetch_chunk(chunk, repository, token, state) do
          {:ok, lifecycles} ->
            {:cont, {%{result | lifecycles: Map.merge(result.lifecycles, lifecycles)}, remaining_budget - 1}}

          {:error, reason} ->
            {:halt, {%{result | error: reason}, remaining_budget - 1}}
        end
    end)
  end

  defp reconcile_fact(%{numbers: []}, _fetched, _state), do: {:ok, nil, false}

  defp reconcile_fact(fact, fetched, state) do
    member_keys = Enum.map(fact.numbers, &Integer.to_string/1)

    if Enum.all?(member_keys, &Map.has_key?(fetched.lifecycles, &1)) do
      with {:ok, changed?} <- write_status(fact.path, Map.take(fetched.lifecycles, member_keys), state) do
        {:ok, fact.path, changed?}
      end
    else
      {:error, fetched.error || :incomplete_graphql_response}
    end
  end

  defp rotate([], _offset), do: []

  defp rotate(items, offset) do
    {before, after_offset} = Enum.split(items, rem(offset, length(items)))
    after_offset ++ before
  end

  defp reconcile_result(results) do
    {paths, changed?, errors} =
      Enum.reduce(results, {[], false, []}, fn
        {:ok, nil, false}, acc -> acc
        {:ok, path, path_changed?}, {paths, changed?, errors} -> {[path | paths], changed? or path_changed?, errors}
        {:error, reason}, {paths, changed?, errors} -> {paths, changed?, [reason | errors]}
      end)

    case errors do
      [] -> {:ok, Enum.reverse(paths), changed?}
      [_ | _] -> {:error, {:pack_refresh_failed, Enum.reverse(errors)}, changed?}
    end
  end

  # Only promoted members have a tracker fact to resolve; drafts stay planned.
  defp pack_facts(pack_path) do
    with {:ok, body} <- File.read(pack_path),
         {:ok, %{"tickets" => tickets} = pack} when is_list(tickets) <- Jason.decode(body),
         {:ok, repository} <- pack_repository(pack) do
      numbers = tickets |> Enum.flat_map(&ticket_number/1) |> Enum.uniq() |> Enum.sort()
      {:ok, repository, numbers}
    else
      _invalid -> {:error, :invalid_pack}
    end
  end

  defp pack_repository(pack) do
    case String.split(to_string(Map.get(pack, "repository", "")), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _invalid -> {:error, :invalid_repository}
    end
  end

  defp ticket_number(%{"ticket" => number}) when is_integer(number) and number > 0, do: [number]
  defp ticket_number(_ticket), do: []

  defp fetch_chunk(numbers, {owner, repo}, token, state) do
    query = issue_state_query(numbers)
    variables = %{"owner" => owner, "name" => repo}

    case Transport.github_graphql(state.request_fun, token, query, variables, caller: :build_order_pack_status) do
      {:ok, %{"data" => %{"repository" => repository}}} when is_map(repository) ->
        complete_lifecycles(numbers, repository)

      {:ok, _body} ->
        {:error, :invalid_graphql_response}

      {:error, reason} ->
        Logger.warning("aiur_build_order_pack_status phase=fetch_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp complete_lifecycles(numbers, repository) do
    lifecycles = lifecycles(repository)
    expected = MapSet.new(numbers, &Integer.to_string/1)
    missing = expected |> MapSet.difference(MapSet.new(Map.keys(lifecycles))) |> Enum.sort()

    case missing do
      [] -> {:ok, lifecycles}
      [_ | _] -> {:error, {:incomplete_graphql_response, missing}}
    end
  end

  # Aliases cannot be GraphQL variables, so they are built from the integer
  # ticket numbers already validated by `ticket_number/1`.
  defp issue_state_query(numbers) do
    fields = Enum.map_join(numbers, "\n    ", &"i#{&1}: issue(number: #{&1}) { number state stateReason }")

    """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        #{fields}
      }
    }
    """
  end

  defp lifecycles(repository) do
    for {_alias, issue} <- repository,
        is_map(issue),
        number = Map.get(issue, "number"),
        is_integer(number),
        lifecycle = lifecycle(Map.get(issue, "state"), Map.get(issue, "stateReason")),
        lifecycle in ["completed", "cancelled", "open"],
        into: %{},
        do: {Integer.to_string(number), lifecycle}
  end

  defp lifecycle(state, reason) do
    state
    |> Lifecycle.from_github(reason)
    |> case do
      %Lifecycle{state: :closed, state_reason: :completed} -> "completed"
      %Lifecycle{state: :closed, state_reason: reason} when reason in [:not_planned, :duplicate] -> "cancelled"
      %Lifecycle{state: :open, state_reason: reason} when reason in [:none, :reopened] -> "open"
      _invalid -> nil
    end
  end

  # --- status.json ------------------------------------------------------------

  defp write_status(pack_path, lifecycles, state) do
    path = PackPaths.status_path(pack_path)
    observed_at = DateTime.to_iso8601(state.now_fun.())

    case read_status(path) do
      {:ok, existing} ->
        merge_status(path, existing, lifecycles, observed_at)

      {:error, reason} = error ->
        Logger.warning("aiur_build_order_pack_status phase=read_failed path=#{path} reason=#{inspect(reason)}")
        error
    end
  end

  defp merge_status(path, existing, lifecycles, observed_at) do
    existing_members = existing |> Map.get("members", %{}) |> then(&if(is_map(&1), do: &1, else: %{}))

    members =
      Map.merge(
        existing_members,
        Map.new(lifecycles, fn {number, lifecycle} ->
          {number, %{"lifecycle" => lifecycle, "observed_at" => observed_at}}
        end)
      )

    # `observed_at` alone would rewrite the projection every cycle; only a
    # changed lifecycle is worth a write.
    if lifecycle_map(existing_members) == lifecycle_map(members) do
      {:ok, false}
    else
      with {:ok, body} <- Jason.encode(Map.put(existing, "members", members), pretty: true),
           :ok <- atomic_write(path, body <> "\n") do
        {:ok, true}
      end
    end
  end

  defp public_result({:ok, paths, _changed?}), do: {:ok, paths}
  defp public_result({:error, reason, _changed?}), do: {:error, reason}

  defp lifecycle_map(members), do: Map.new(members, fn {number, member} -> {number, member_lifecycle(member)} end)

  defp member_lifecycle(%{"lifecycle" => lifecycle}), do: lifecycle
  defp member_lifecycle(%{"state" => state}), do: state
  defp member_lifecycle(lifecycle) when is_binary(lifecycle), do: lifecycle
  defp member_lifecycle(_member), do: nil

  defp read_status(path) do
    case File.read(path) do
      {:ok, body} -> decode_status(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:status_read_failed, reason}}
    end
  end

  defp decode_status(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :invalid_status}
    end
  end

  # A torn status.json would reset completion to unknown, so the projection is
  # replaced by rename rather than written in place.
  defp atomic_write(path, body) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Fs.atomic_write(path, body, fsync: true) do
      :ok
    else
      error ->
        Logger.warning("aiur_build_order_pack_status phase=write_failed reason=#{inspect(error)}")
        error
    end
  end
end
