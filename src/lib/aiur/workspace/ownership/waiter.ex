defmodule Aiur.Workspace.Ownership.Waiter do
  @moduledoc false

  alias Aiur.Workspace.Ownership

  @subscribe_timeout_ms 100

  @spec wait(String.t(), pid(), pid() | atom()) :: :waiting | :available
  def wait(ticket, recipient, registry) do
    caller = self()
    waiter = spawn(fn -> subscribe(ticket, recipient, registry, caller, true) end)

    receive do
      {:workspace_waiter_ready, ^waiter, result} -> result
    end
  end

  defp subscribe(ticket, recipient, registry, caller, initial?) do
    case Ownership.current(ticket, registry) do
      {:ok, %{guardian: guardian, generation: generation}} when is_pid(guardian) ->
        monitor = Process.monitor(guardian)
        ref = make_ref()
        send(guardian, {:workspace_guardian_call, self(), ref, {:wait_for_release, self()}})

        await_subscription(%{
          ticket: ticket,
          recipient: recipient,
          registry: registry,
          caller: caller,
          initial?: initial?,
          guardian: guardian,
          generation: generation,
          monitor: monitor,
          ref: ref
        })

      :none ->
        notify_available(ticket, recipient, caller, initial?)
    end
  end

  defp await_subscription(%{ref: ref, generation: generation} = subscription) do
    receive do
      {:workspace_guardian_reply, ^ref, {:waiting, ^generation}} ->
        if exact_guardian?(subscription) do
          notify_waiting(subscription)
          await_release(subscription)
        else
          resubscribe(subscription)
        end

      {:DOWN, monitor, :process, guardian, _reason}
      when monitor == subscription.monitor and guardian == subscription.guardian ->
        resubscribe(subscription)
    after
      @subscribe_timeout_ms ->
        resubscribe(subscription)
    end
  end

  defp await_release(subscription) do
    receive do
      {:workspace_ownership_available, ticket, guardian, generation}
      when ticket == subscription.ticket and guardian == subscription.guardian and generation == subscription.generation ->
        send(subscription.recipient, {:workspace_ownership_available, ticket})

      {:workspace_ownership_available, ticket, _guardian, _generation} when ticket == subscription.ticket ->
        resubscribe(subscription)

      {:DOWN, monitor, :process, guardian, _reason}
      when monitor == subscription.monitor and guardian == subscription.guardian ->
        subscribe(subscription.ticket, subscription.recipient, subscription.registry, self(), false)
    end
  end

  defp exact_guardian?(subscription) do
    %{ticket: ticket, registry: registry, guardian: guardian, generation: generation} = subscription
    match?({:ok, %{guardian: ^guardian, generation: ^generation}}, Ownership.current(ticket, registry))
  end

  defp notify_waiting(%{initial?: true, caller: caller}), do: send(caller, {:workspace_waiter_ready, self(), :waiting})
  defp notify_waiting(_subscription), do: :ok

  defp resubscribe(subscription) do
    Process.demonitor(subscription.monitor, [:flush])
    subscribe(subscription.ticket, subscription.recipient, subscription.registry, subscription.caller, subscription.initial?)
  end

  defp notify_available(_ticket, _recipient, caller, true), do: send(caller, {:workspace_waiter_ready, self(), :available})

  defp notify_available(ticket, recipient, _caller, false), do: send(recipient, {:workspace_ownership_available, ticket})
end
