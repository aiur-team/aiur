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
  resolves their tracker state in one batched GraphQL call per 50 members, and
  merges the result into `status.json`. Unrelated keys in that file (`state`,
  `completed_at`, operator annotations) are preserved. A failed or partial
  fetch leaves the previous projection untouched — a stale completion fact is
  strictly better than silently reverting a merged ticket to 0%.
  """

  use GenServer

  require Logger

  alias Aiur.BuildOrder.PackPaths
  alias Aiur.GitHub.Transport

  @default_interval :timer.minutes(5)
  @chunk_size 50

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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      inflight: nil,
      interval: Keyword.get(opts, :poll_interval, @default_interval),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      paths_fun: Keyword.get(opts, :paths_fun, &PackPaths.discovered/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    }

    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh_sync, _from, state), do: {:reply, reconcile(state), state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, ensure_reconcile(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> ensure_reconcile() |> schedule_next()}

  def handle_info({ref, _result}, %{inflight: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | inflight: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: ref} = state),
    do: {:noreply, %{state | inflight: nil}}

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

  # --- reconcile --------------------------------------------------------------

  @spec reconcile(map()) :: {:ok, [Path.t()]} | {:error, term()}
  defp reconcile(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      written =
        state.paths_fun.()
        |> Enum.flat_map(&reconcile_pack(&1, {owner, repo}, token, state))

      {:ok, written}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reconcile_pack(pack_path, repository, token, state) do
    with {:ok, numbers} <- promoted_numbers(pack_path),
         [_ | _] <- numbers,
         {:ok, lifecycles} <- fetch_lifecycles(numbers, repository, token, state) do
      case write_status(pack_path, lifecycles, state) do
        :ok -> [pack_path]
        _error -> []
      end
    else
      _skip -> []
    end
  end

  # Only promoted members have a tracker fact to resolve; drafts stay planned.
  defp promoted_numbers(pack_path) do
    with {:ok, body} <- File.read(pack_path),
         {:ok, %{"tickets" => tickets}} when is_list(tickets) <- Jason.decode(body) do
      {:ok, tickets |> Enum.flat_map(&ticket_number/1) |> Enum.uniq() |> Enum.sort()}
    else
      _invalid -> :error
    end
  end

  defp ticket_number(%{"ticket" => number}) when is_integer(number) and number > 0, do: [number]
  defp ticket_number(_ticket), do: []

  defp fetch_lifecycles(numbers, repository, token, state) do
    numbers
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case fetch_chunk(chunk, repository, token, state) do
        {:ok, lifecycles} -> {:cont, {:ok, Map.merge(acc, lifecycles)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_chunk(numbers, {owner, repo}, token, state) do
    query = issue_state_query(numbers)
    variables = %{"owner" => owner, "name" => repo}

    case Transport.github_graphql(state.request_fun, token, query, variables) do
      {:ok, %{"data" => %{"repository" => repository}}} when is_map(repository) ->
        {:ok, lifecycles(repository)}

      {:ok, _body} ->
        {:error, :invalid_graphql_response}

      {:error, reason} ->
        Logger.warning("aiur_build_order_pack_status phase=fetch_failed reason=#{inspect(reason)}")
        {:error, reason}
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
        into: %{},
        do: {Integer.to_string(number), lifecycle}
  end

  defp lifecycle("CLOSED", reason) when reason in ["NOT_PLANNED", "DUPLICATE"], do: "cancelled"
  defp lifecycle("CLOSED", _reason), do: "completed"
  defp lifecycle("OPEN", _reason), do: "open"
  defp lifecycle(_state, _reason), do: nil

  # --- status.json ------------------------------------------------------------

  defp write_status(pack_path, lifecycles, state) do
    path = PackPaths.status_path(pack_path)
    observed_at = DateTime.to_iso8601(state.now_fun.())
    existing = read_status(path)
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
      :ok
    else
      with {:ok, body} <- Jason.encode(Map.put(existing, "members", members), pretty: true) do
        atomic_write(path, body <> "\n")
      end
    end
  end

  defp lifecycle_map(members), do: Map.new(members, fn {number, member} -> {number, member_lifecycle(member)} end)

  defp member_lifecycle(%{"lifecycle" => lifecycle}), do: lifecycle
  defp member_lifecycle(%{"state" => state}), do: state
  defp member_lifecycle(lifecycle) when is_binary(lifecycle), do: lifecycle
  defp member_lifecycle(_member), do: nil

  defp read_status(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _missing -> %{}
    end
  end

  # A torn status.json would reset completion to unknown, so the projection is
  # replaced by rename rather than written in place.
  defp atomic_write(path, body) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, body),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        Logger.warning("aiur_build_order_pack_status phase=write_failed reason=#{inspect(error)}")
        error
    end
  end
end
