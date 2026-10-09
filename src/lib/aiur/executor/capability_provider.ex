defmodule Aiur.Executor.CapabilityProvider do
  @moduledoc "Read-only Executor presence and wake availability."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider
  alias Aiur.Executor.{Claims, Roster}

  @impl true
  def capability_ids, do: ~w(executor.wakes executor.conversation)

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(_context, opts \\ []) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)

    %{
      "executor.wakes" => if(lookup.(Aiur.ExecutorWakeInbox), do: %{state: :available}, else: %{state: :unavailable, reason: :not_running}),
      "executor.conversation" => %{state: :unavailable, reason: :executor_not_managed}
    }
  end

  @impl true
  def sections(context), do: executor(context)

  @spec executor(Provider.context(), keyword()) :: map()
  def executor(_context, opts \\ []) do
    claim_opts = Keyword.take(opts, [:path, :now])
    owner = Keyword.get(opts, :owner_fun, &Claims.owner/1).(claim_opts)
    roster = Keyword.get(opts, :roster_fun, &Roster.build/1).(Keyword.put(claim_opts, :record?, false))
    %{executor: describe(owner, roster.executors)}
  rescue
    _error -> %{executor: %{state: "unknown"}}
  catch
    :exit, _reason -> %{executor: %{state: "unknown"}}
  end

  @spec live?(map()) :: boolean()
  def live?(%{state: state}), do: state in ["active", "idle", :active, :idle]
  def live?(_executor), do: false

  defp describe({:ok, owner}, entries) do
    entry = Enum.find(entries, &(&1.id == owner["id"]))
    state = if entry, do: to_string(entry.state), else: "unknown"
    %{state: state, consumer_id: owner["id"], harness: nil}
  end

  defp describe(:none, []), do: %{state: "absent", consumer_id: nil}

  defp describe(:none, entries) do
    state = if Enum.all?(entries, &(&1.state == :expired)), do: "expired", else: "unknown"
    %{state: state, consumer_id: nil}
  end
end
