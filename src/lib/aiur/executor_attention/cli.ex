defmodule Aiur.ExecutorAttention.CLI do
  @moduledoc false
  alias Aiur.ControlCLI.Reasons
  alias Aiur.Executor.{Claims, Roster}
  alias Aiur.{ExecutorEvents, ExecutorWakeInbox}

  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1]

  @spec executor_emit(String.t(), String.t()) :: :ok
  def executor_emit(topic, payload_json) when is_binary(topic) and is_binary(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, %{} = payload} ->
        case ExecutorEvents.publish(topic, payload, source: :executor_cli) do
          {:ok, id, _subscribers} ->
            IO.puts(Jason.encode!(%{id: id, topic: topic}))
            exit_marker(0)

          {:error, reason} ->
            IO.puts(:stderr, "aiur: executor event rejected (#{Reasons.format_reason(reason)})")
            exit_marker(1)
        end

      _ ->
        IO.puts(:stderr, "aiur: executor-emit payload must be a JSON object")
        exit_marker(64)
    end
  end

  @spec executor_subscribe(String.t()) :: :ok
  def executor_subscribe(topic) when is_binary(topic) do
    executor_subscription_result(ExecutorEvents.subscribe(topic), "subscribed", topic)
  end

  @spec executor_unsubscribe(String.t()) :: :ok
  def executor_unsubscribe(topic) when is_binary(topic) do
    executor_subscription_result(ExecutorEvents.unsubscribe(topic), "unsubscribed", topic)
  end

  @spec executor_subscriptions() :: :ok
  def executor_subscriptions do
    ExecutorEvents.subscriptions() |> Enum.each(&IO.puts/1)
    exit_marker(0)
  end

  @spec executor_listen(keyword()) :: no_return()
  def executor_listen(opts \\ []), do: ExecutorEvents.listen(opts)

  @doc """
  Waits for Executor wake records, auto-claiming the stream when nobody holds
  it.

  There is no detection of "is this an agent" anywhere in this path — the caller
  simply claims. A caller that gets the claim is the owner and acknowledges, so
  the shared cursor advances exactly once per record. A caller refused by a
  live, renewing owner reads the same records as a read-only observer and never
  advances the cursor, so two consumers cannot split the stream between them.

  ## Outcomes

  Exit `0` covers both delivery and a quiet timeout: a wait that ends with no
  wake consumed nothing and lost nothing, so it is a successful empty result,
  not a failure (#2600). Every nonzero exit names the stage that failed —
  `claim`, `wait` or `acknowledge` — on stderr, and in `--json` mode as a
  `status: "error"` envelope. Exit `69` is reserved for contention on the shared
  claim, which is retryable and reports the retry bounds already spent; exit `1`
  is a daemon or store failure, which is not.
  """

  @spec executor_wait(keyword()) :: :ok
  def executor_wait(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    json? = Keyword.get(opts, :json, false)
    consumer_id = Claims.resolve_consumer_id(opts)

    case executor_wait_role(consumer_id) do
      {:ok, role, holder} -> executor_wait_as(consumer_id, role, holder, timeout_ms, json?)
      {:error, reason} -> executor_wait_failure(:claim, executor_wait_detail(reason), reason, :unknown, json?)
    end
  end

  defp executor_wait_as(consumer_id, role, holder, timeout_ms, json?) do
    announce_executor_peers(consumer_id, holder)

    # A quiet wait can outlast a lease, and an owner that silently expired
    # mid-wait would be refused its own acknowledgement and re-read the same
    # records forever. Renew from a helper process for as long as the wait runs.
    renewer = start_lease_renewer(consumer_id)

    try do
      result = ExecutorWakeInbox.wait(timeout_ms)
      executor_wait_result(result, consumer_id, renewed_wait_role(role, renewer), json?, timeout_ms)
    after
      stop_lease_renewer(renewer)
    end
  end

  # A refusal by a live owner is a supported outcome and reads as an observer.
  # Anything else means the claim store could not be arbitrated at all, and
  # waiting under it would print records nobody can acknowledge — the silent
  # no-progress loop #2600 reported. Fail with the stage instead.
  defp executor_wait_role(consumer_id) do
    case Claims.claim(consumer_id) do
      {:ok, _entry} ->
        {:ok, :owner, nil}

      {:error, {:held_by, owner}} ->
        _ = Claims.observe(consumer_id)
        {:ok, :observer, owner}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_lease_renewer(consumer_id) do
    interval = max(div(Claims.lease_ttl_ms(), 3), 1_000)
    waiter = self()
    spawn_link(fn -> renew_lease_forever(consumer_id, interval, waiter) end)
  end

  defp renew_lease_forever(consumer_id, interval, waiter) do
    receive do
      :renew -> :ok
    after
      interval -> :ok
    end

    case Claims.renew(consumer_id) do
      {:error, :not_owner} -> send(waiter, {:executor_ownership_lost, self()})
      {:ok, %{"role" => role}} when role != "owner" -> send(waiter, {:executor_ownership_lost, self()})
      _ -> :ok
    end

    renew_lease_forever(consumer_id, interval, waiter)
  end

  defp renewed_wait_role(role, renewer) do
    receive do
      {:executor_ownership_lost, ^renewer} ->
        if role == :owner, do: control_error("aiur: this consumer is not the live owner of the wake stream; continuing as observer")
        :observer
    after
      0 -> role
    end
  end

  defp stop_lease_renewer(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  # The batch is printed before it is acknowledged, deliberately. The reverse
  # order would advance the cursor while the records were still only inside the
  # control RPC's buffered stdout, which the launcher discards outright when its
  # own budget expires — turning a benign redelivery into permanent, silent wake
  # loss. Losing a wake is the worse failure, so the ordering stays; what changes
  # is that a refused acknowledgement is now a diagnosed nonzero exit naming the
  # stage and the ids, instead of an exit 0 that read as a successful consume.
  defp executor_wait_result({:ok, records}, consumer_id, role, json?, _timeout_ms) do
    print_executor_wakes(records, json?, role)

    case acknowledge_executor_wakes(records, consumer_id, role) do
      :ok ->
        exit_marker(0)

      {:error, reason} ->
        executor_wait_failure(
          :acknowledge,
          unacknowledged_detail(records, reason),
          reason,
          role,
          json?,
          %{"unconsumed_wake_ids" => Enum.map(records, & &1["wake_id"])}
        )
    end
  end

  # A quiet wait consumed nothing and lost nothing. Reporting that as a failure
  # gave the caller an exit code with no diagnostic behind it, which is how a
  # perfectly healthy idle wait came to look like a broken daemon (#2600).
  defp executor_wait_result(:timeout, _consumer_id, role, json?, timeout_ms) do
    print_executor_quiet(role, json?, timeout_ms)
    exit_marker(0)
  end

  defp executor_wait_result({:error, reason}, _consumer_id, role, json?, _timeout_ms) do
    executor_wait_failure(:wait, executor_wait_detail(reason), reason, role, json?)
  end

  defp print_executor_quiet(role, true, timeout_ms),
    do: IO.puts(Jason.encode!(%{"status" => "timeout", "role" => role, "records" => [], "timeout_ms" => timeout_ms}))

  defp print_executor_quiet(role, false, timeout_ms),
    do: IO.puts("NO-WAKES role=#{role} timeout_ms=#{timeout_ms} nothing pending, nothing consumed")

  defp executor_wait_failure(stage, detail, reason, role, json?, extra \\ %{}) do
    control_error("aiur: executor-wait failed at the #{stage} stage - #{detail}")

    if json? do
      IO.puts(
        Jason.encode!(
          Map.merge(
            %{"status" => "error", "stage" => to_string(stage), "role" => role, "records" => [], "detail" => detail},
            extra
          )
        )
      )
    end

    exit_marker(executor_wait_exit_code(reason))
  end

  # Contention on the shared claim is the one nonzero outcome a caller may retry
  # unchanged, so it gets its own code. Everything else is a daemon or store
  # failure that retrying will only repeat.
  defp executor_wait_exit_code({:executor_claims_lock_timeout, _lock}), do: 69
  defp executor_wait_exit_code({:not_owner, _owner}), do: 69
  defp executor_wait_exit_code(_reason), do: 1

  defp unacknowledged_detail(records, reason) do
    ids = records |> Enum.map(& &1["wake_id"]) |> Enum.reject(&is_nil/1)

    range =
      case ids do
        [] -> "#{length(records)} wakes"
        ids -> "#{length(records)} wakes (ids #{Enum.min(ids)}-#{Enum.max(ids)})"
      end

    "#{executor_wait_detail(reason)}; #{range} were NOT consumed, the cursor did not advance, " <>
      "and they will be delivered again"
  end

  defp executor_wait_detail({:executor_claims_lock_timeout, lock}) do
    %{timeout_ms: timeout_ms, retry_interval_ms: interval_ms, stale_after_seconds: stale_after_seconds} =
      Claims.lock_retry_budget()

    "wake-stream lock contention: #{lock} was still held after retrying every #{interval_ms}ms for #{timeout_ms}ms " <>
      "(a lock older than #{stale_after_seconds}s is broken as stale). Nothing was consumed, so this is safe to retry"
  end

  defp executor_wait_detail({:executor_claims_lock_unavailable, lock, reason}) do
    "claims store unavailable: the lock #{lock} could not be created (#{Reasons.format_reason(reason)}). " <>
      "This is a store failure, not contention, and retrying will repeat it"
  end

  defp executor_wait_detail({:executor_claims_unavailable, message}),
    do: "claims store write failed (#{message}). This is a store failure, not contention"

  defp executor_wait_detail({:not_owner, owner}) do
    "cursor-write contention: the wake stream claim is now held by #{(owner && owner["id"]) || "nobody"}, " <>
      "so this consumer can only read as an observer until that claim is released or revoked"
  end

  defp executor_wait_detail(reason), do: "executor wake inbox unavailable (#{Reasons.format_reason(reason)})"

  @doc "Fast-forwards the owner cursor through an externally covered durable wake id."
  @spec executor_fast_forward(pos_integer(), keyword()) :: :ok
  def executor_fast_forward(wake_id, opts \\ []) when is_integer(wake_id) and wake_id > 0 do
    consumer_id = Claims.resolve_consumer_id(opts)

    case Claims.claim(consumer_id) do
      {:ok, _entry} ->
        executor_fast_forward_result(ExecutorWakeInbox.fast_forward_as(consumer_id, wake_id))

      {:error, {:held_by, owner}} ->
        executor_fast_forward_observer(owner)

      {:error, reason} ->
        control_error("aiur: could not claim the wake stream (#{Reasons.format_reason(reason)}); fast-forward refused and the cursor did not advance")
        exit_marker(1)
    end
  end

  defp executor_fast_forward_result({:ok, result}) do
    IO.puts(
      "FAST-FORWARDED from=#{result.from} through=#{result.through} " <>
        "acknowledged=#{result.acknowledged_count} pending=#{result.pending_count}"
    )

    exit_marker(0)
  end

  defp executor_fast_forward_result({:error, {:beyond_latest_wake, latest}}) do
    control_error("aiur: cannot fast-forward beyond latest durable wake #{latest}")
    exit_marker(1)
  end

  defp executor_fast_forward_result({:error, {:wake_not_found, wake_id}}) do
    control_error("aiur: wake #{wake_id} is not present in the durable inbox")
    exit_marker(1)
  end

  defp executor_fast_forward_result({:error, reason}) do
    control_error("aiur: executor fast-forward failed (#{Reasons.format_reason(reason)}); the cursor did not advance")
    exit_marker(1)
  end

  defp executor_fast_forward_observer(owner) do
    owner_id = (owner && owner["id"]) || "another consumer"
    control_error("aiur: wake stream is held by #{owner_id}; fast-forward refused and the cursor did not advance")
    exit_marker(1)
  end

  # An observer deliberately does not advance the shared cursor; only an owner's
  # acknowledgement does. A failed owner acknowledgement is never swallowed: it
  # means the cursor did not move and the same records come back on the next
  # wait, which otherwise reads as a working consumer looping.
  defp acknowledge_executor_wakes(_records, _consumer_id, :observer), do: :ok

  defp acknowledge_executor_wakes(records, consumer_id, :owner),
    do: ExecutorWakeInbox.acknowledge_as(consumer_id, records)

  # An agent that finds a peer tells the operator, unprompted, with the evidence
  # rather than a verdict. A healthy peer is reported plainly; multiple
  # executors are a supported configuration, not a fault.
  defp announce_executor_peers(consumer_id, holder) do
    peers =
      Roster.build(record?: false).executors
      |> Enum.reject(&(&1.id == consumer_id or &1.state == :expired))

    Enum.each(peers, fn peer -> IO.puts("PEER " <> Roster.describe_line(peer)) end)

    if holder do
      IO.puts("PEER-OWNER #{holder["id"]} holds the wake stream; reading as observer. Revoke is an operator decision.")
    end
  end

  @doc "Prints the Executor roster with the liveness evidence behind each state."
  @spec executor_roster(keyword()) :: :ok
  def executor_roster(opts \\ []) do
    roster = Roster.build(Keyword.take(opts, [:now, :stall_after_ms]))

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(roster))
    else
      IO.puts("CURSOR #{roster.cursor} PENDING #{roster.pending_count}")

      case roster.executors do
        [] -> IO.puts("EXECUTORS none")
        executors -> Enum.each(executors, &IO.puts(Roster.describe_line(&1)))
      end
    end

    exit_marker(0)
  end

  @doc "Claims the wake stream, or refuses and names the live owner holding it."
  @spec executor_claim(keyword()) :: :ok
  def executor_claim(opts \\ []) do
    consumer_id = Claims.resolve_consumer_id(opts)

    case Claims.claim(consumer_id) do
      {:ok, entry} ->
        IO.puts("CLAIMED #{entry["id"]} lease_expires_at=#{entry["lease_expires_at"]}")
        exit_marker(0)

      {:error, {:held_by, owner}} ->
        control_error(
          "aiur: wake stream is held by #{owner["id"]} (host=#{owner["host"]} pid=#{owner["pid"]} " <>
            "last_renewed_at=#{owner["last_renewed_at"]}); it is live and renewing, so takeover needs an explicit " <>
            "`aiur executor-revoke #{owner["id"]}` from the operator"
        )

        exit_marker(1)

      {:error, reason} ->
        control_error("aiur: executor claim failed (#{Reasons.format_reason(reason)})")
        exit_marker(1)
    end
  end

  @doc "Releases this consumer's claim so the stream is immediately free."
  @spec executor_release(keyword()) :: :ok
  def executor_release(opts \\ []) do
    consumer_id = Claims.resolve_consumer_id(opts)

    case Claims.release(consumer_id) do
      :ok ->
        IO.puts("RELEASED #{consumer_id}")
        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: executor release failed (#{Reasons.format_reason(reason)})")
        exit_marker(1)
    end
  end

  @doc """
  Explicit operator revoke of a named live owner.

  Deliberately requires the owner's id: an agent recommends a revoke from the
  roster evidence, the operator decides. Nothing revokes a live peer implicitly.
  """
  @spec executor_revoke(String.t(), keyword()) :: :ok
  def executor_revoke(owner_id, opts \\ []) when is_binary(owner_id) do
    case Claims.revoke(owner_id, Keyword.take(opts, [:now])) do
      {:ok, entry} ->
        IO.puts("REVOKED #{entry["id"]}")
        exit_marker(0)

      {:error, :no_owner} ->
        control_error("aiur: no live owner holds the wake stream")
        exit_marker(1)

      {:error, :not_owner} ->
        control_error("aiur: #{owner_id} is not the live owner of the wake stream")
        exit_marker(1)

      {:error, reason} ->
        control_error("aiur: executor revoke failed (#{Reasons.format_reason(reason)})")
        exit_marker(1)
    end
  end

  defp print_executor_wakes(records, true, role),
    do: IO.puts(Jason.encode!(%{"status" => "woken", "role" => role, "records" => records}))

  defp print_executor_wakes(records, false, role) do
    Enum.each(records, fn record ->
      ticket = if record["ticket"], do: " ticket=#{record["ticket"]}", else: ""
      observation = if record["observation"] == "initial_sync", do: " observation=initial_sync", else: ""
      IO.puts("WAKE #{record["topic"]}#{ticket} count=#{record["count"]} role=#{role}#{observation}")
    end)
  end

  defp executor_subscription_result(:ok, action, topic) do
    IO.puts("#{action} #{topic}")
    exit_marker(0)
  end

  defp executor_subscription_result({:error, reason}, _action, _topic) do
    IO.puts(:stderr, "aiur: executor subscription rejected (#{Reasons.format_reason(reason)})")
    exit_marker(1)
  end
end
