defmodule Aiur.RunTelemetry.FactsCapture do
  @moduledoc "Durable, serial, budget-aware terminal-ticket PR fact capture."
  use GenServer
  require Logger

  alias Aiur.Config.ObservabilitySettings
  alias Aiur.GitHub.Errors
  alias Aiur.RunTelemetry.{GitHubFacts, Lifecycle, Summaries, Writer}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]) |> Keyword.put_new(:name, __MODULE__) |> Enum.reject(fn {_, v} -> is_nil(v) end))
  end

  @doc "Queues a terminal ticket, including backfills; completed tickets are deduplicated across boots."
  @spec capture(String.t(), GenServer.server()) :: :ok
  def capture(ticket, server \\ __MODULE__) when is_binary(ticket) do
    GenServer.cast(server, {:capture, ticket})
  end

  @doc false
  @spec observe(map(), GenServer.server()) :: :ok
  def observe(attributes, server \\ __MODULE__) do
    event = attributes[:event] || attributes["event"]
    terminal = (attributes[:state] || attributes["state"]) in ["done", "closed", "cancelled", "canceled"]
    ticket = attributes[:ticket] || attributes["ticket"]

    if is_binary(ticket) and (event in [:pr_merged, "pr_merged"] or (event in [:state_change, "state_change"] and terminal)),
      do: GenServer.cast(server, {:capture, if(event in [:pr_merged, "pr_merged"], do: ticket <> ":merged", else: ticket)}),
      else: :ok
  end

  @doc false
  @spec terminal(Aiur.TrackerIdentity.t(), atom()) :: :ok
  def terminal(%Aiur.TrackerIdentity{kind: :github, identifier: ticket}, lifecycle) when lifecycle in [:completed, :cancelled], do: capture(ticket)
  def terminal(_identity, _lifecycle), do: :ok

  @doc false
  @spec drain(GenServer.server()) :: :ok
  def drain(server), do: GenServer.call(server, :drain)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> Path.join(Summaries.analytics_dir(), "facts-pending.json") end)
    stored = load(path)

    state = %{
      path: path,
      storage_available: stored["unavailable"] != true,
      pending: stored["pending"] || %{},
      captured_keys: stored["completed"] || [],
      enabled: Keyword.get(opts, :enabled, &ObservabilitySettings.capture_github_facts?/0),
      fetch: Keyword.get(opts, :fetch, &GitHubFacts.fetch/1),
      record: Keyword.get(opts, :record, &record_facts/2),
      interval: Keyword.get(opts, :interval, 5_000),
      task: nil
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:capture, ticket}, state) do
    if state.enabled.() and ticket not in state.captured_keys and not Map.has_key?(state.pending, ticket) do
      state = %{state | pending: Map.put(state.pending, ticket, %{"attempts" => 0})}
      persist(state)
      send(self(), :work)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, :ok, work(state)}

  @impl true
  def handle_info(:work, state), do: {:noreply, work(state)}

  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, work(state)}
  end

  def handle_info({ref, result}, %{task: {ref, ticket}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(%{state | task: nil}, ticket, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {ref, ticket}} = state),
    do: {:noreply, finish(%{state | task: nil}, ticket, {:error, :capture_worker_exit})}

  def handle_info(_message, state), do: {:noreply, state}

  defp work(%{storage_available: false} = state), do: state

  defp work(%{task: task} = state) when not is_nil(task), do: state

  defp work(state) do
    if state.enabled.(), do: work_enabled(state), else: state
  end

  defp work_enabled(state) do
    case Enum.find(state.pending, fn {_ticket, entry} -> (entry["next_at"] || 0) <= System.system_time(:millisecond) end) do
      {ticket, %{"facts" => facts}} -> publish(state, ticket, facts)
      {ticket, _entry} -> start_fetch(state, ticket)
      nil -> state
    end
  end

  defp start_fetch(state, ticket) do
    case persist(state) do
      :ok ->
        task = Task.async(fn -> safe_fetch(state.fetch, bare_ticket(ticket)) end)
        %{state | task: {task.ref, ticket}}

      _error ->
        state
    end
  end

  defp safe_fetch(fetch, ticket) do
    fetch.(ticket)
  rescue
    _ -> {:error, :capture_exception}
  catch
    _, _ -> {:error, :capture_exception}
  end

  defp finish(state, ticket, {:ok, facts}), do: retain_and_publish(state, ticket, facts)

  defp finish(state, ticket, result) do
    entry = Map.fetch!(state.pending, ticket)
    held = Errors.outcome(result) == :held or result == {:error, :github_budget_broker_timeout}
    attempts = entry["attempts"] + if(held, do: 0, else: 1)

    if attempts >= 3 do
      retain_and_publish(state, ticket, %{coverage: "unavailable"})
    else
      entry = %{"attempts" => attempts, "next_at" => System.system_time(:millisecond) + state.interval * max(attempts, 1)}
      state = %{state | pending: Map.put(state.pending, ticket, entry)}
      persist(state)
      state
    end
  end

  defp retain_and_publish(state, ticket, facts) do
    entry = Map.put(Map.fetch!(state.pending, ticket), "facts", facts)
    state = %{state | pending: Map.put(state.pending, ticket, entry)}
    if persist(state) == :ok, do: publish(state, ticket, facts), else: state
  end

  defp publish(state, ticket, facts) do
    if state.record.(bare_ticket(ticket), facts) == :ok do
      completed = completion_keys(ticket, facts) ++ state.captured_keys
      state = %{state | pending: Map.drop(state.pending, completion_keys(ticket, facts)), captured_keys: Enum.uniq(completed)}
      persist(state)
      state
    else
      state
    end
  end

  defp bare_ticket(key), do: key |> String.split(":", parts: 2) |> hd()

  defp completion_keys(key, facts) do
    ticket = bare_ticket(key)
    if (String.ends_with?(key, ":merged") or facts[:merged_at]) || facts["merged_at"], do: [ticket <> ":merged", ticket], else: [ticket]
  end

  defp record_facts(ticket, facts) do
    Writer.record_sync(Writer, :lifecycle, Lifecycle.facts_attributes(ticket, facts), [])
  end

  defp schedule(%{interval: interval}) do
    Process.send_after(self(), :tick, interval)
  end

  defp load(path) do
    case File.read(path) do
      {:error, :enoent} -> %{}
      {:ok, bytes} -> decode_queue(bytes)
      _ -> unavailable_queue()
    end
  end

  defp decode_queue(bytes) do
    with {:ok, %{"pending" => pending, "completed" => completed} = stored} <- Jason.decode(bytes),
         true <- is_map(pending) and is_list(completed),
         true <- Enum.all?(completed, &is_binary/1),
         true <- Enum.all?(pending, &valid_entry?/1) do
      stored
    else
      _ -> unavailable_queue()
    end
  end

  defp valid_entry?({ticket, %{"attempts" => attempts} = entry}) do
    is_binary(ticket) and is_integer(attempts) and attempts >= 0 and
      (is_nil(entry["next_at"]) or is_integer(entry["next_at"])) and
      (is_nil(entry["facts"]) or is_map(entry["facts"]))
  end

  defp valid_entry?(_entry), do: false

  defp unavailable_queue do
    Logger.warning("analytics_facts queue_unavailable; preserving file and deferring reads until restart")
    %{"unavailable" => true}
  end

  defp persist(%{storage_available: false}), do: {:error, :queue_unavailable}

  defp persist(state) do
    temporary = state.path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(temporary, Jason.encode!(%{pending: state.pending, completed: state.captured_keys}), [:sync]),
         :ok <- File.rename(temporary, state.path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("analytics_facts queue_write_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end
end
