defmodule Aiur.ExecutorAttention.DeferredWait do
  @moduledoc false

  alias Aiur.ExecutorWakeInbox

  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1]

  @spec acknowledge_through(String.t(), atom(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def acknowledge_through(_consumer_id, _role, nil), do: :ok

  def acknowledge_through(consumer_id, :owner, wake_id) when is_integer(wake_id) and wake_id >= 0 do
    case ExecutorWakeInbox.fast_forward_as(consumer_id, wake_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def acknowledge_through(consumer_id, :observer, _wake_id), do: {:error, {:not_owner, %{"id" => consumer_id}}}
  def acknowledge_through(_consumer_id, _role, _wake_id), do: {:error, :invalid_ack_through}

  @spec superseded(atom(), boolean()) :: :ok
  def superseded(role, true) do
    IO.puts(Jason.encode!(%{"status" => "superseded", "role" => role, "records" => []}))
    exit_marker(0)
  end

  def superseded(_role, false) do
    IO.puts("SUPERSEDED nothing consumed")
    exit_marker(0)
  end

  @spec print_wakes([map()], boolean(), atom(), boolean()) :: :ok
  def print_wakes(records, true, role, false),
    do: IO.puts(Jason.encode!(%{"status" => "woken", "role" => role, "records" => records}))

  def print_wakes(records, true, role, true) do
    max_wake_id = records |> Enum.map(& &1["wake_id"]) |> Enum.max(fn -> 0 end)
    IO.puts(Jason.encode!(%{"status" => "woken", "role" => role, "records" => records, "ack" => "deferred", "max_wake_id" => max_wake_id}))
  end

  def print_wakes(records, false, role, _defer_ack?) do
    Enum.each(records, fn record ->
      ticket = if record["ticket"], do: " ticket=#{record["ticket"]}", else: ""
      observation = if record["observation"] == "initial_sync", do: " observation=initial_sync", else: ""
      decision = if record["decision_id"], do: " decision=#{record["decision_id"]} gates=#{record["gates"]} escalation=#{record["escalation"]}", else: ""
      IO.puts("WAKE #{record["topic"]}#{ticket} count=#{record["count"]} role=#{role}#{observation}#{decision}")
    end)
  end
end
