defmodule Aiur.BuildQueueFakeTracker do
  @moduledoc false
  alias Aiur.GitHub.Labels

  def reset(document, now \\ 1_000) do
    Process.put(__MODULE__, %{document: document, now: now, calls: [], saves: [], labels: %{}, result: :ok, save_result: :ok, ensure_result: :ok})
  end

  def get(key), do: Process.get(__MODULE__)[key]
  def put(key, value), do: Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, value))
  def clock, do: get(:now)
  def sleep(delay), do: put(:delays, (get(:delays) || []) ++ [delay])

  def save(document) do
    put(:saves, get(:saves) ++ [document])

    result = if get(:save_failure_at) == length(get(:saves)), do: {:error, :disk_full}, else: get(:save_result)

    case result do
      :ok ->
        put(:document, document)
        :ok

      error ->
        error
    end
  end

  def update_issue_state(id, "todo", expected_state: :none) do
    record({:update_issue_state, id, "todo", [expected_state: :none]})
    labels = Map.get(get(:labels), id, ["agent:queued"])
    states = Enum.filter(labels, &(&1 in Labels.state_labels("agent")))
    result = if states == [], do: get(:result), else: {:error, {:stale_issue_state, :none, states}}
    if result == :ok, do: put(:labels, Map.put(get(:labels), id, labels ++ ["agent:todo"]))
    put(:now, clock() + (get(:write_advance_ms) || 0))
    result
  end

  def ensure_labels(labels) do
    record({:ensure_labels, labels})
    get(:ensure_result)
  end

  def add_label(id, label) do
    record({:add_label, id, label})
    get(:result)
  end

  def remove_label(id, label) do
    record({:remove_label, id, label})
    get(:result)
  end

  def notify_demand(ids), do: record({:notify_demand, ids})

  defp record(call) do
    put(:calls, get(:calls) ++ [{call, get(:document)}])
    :ok
  end
end
