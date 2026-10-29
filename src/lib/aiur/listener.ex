defmodule Aiur.Listener do
  @moduledoc "Public C1 port for listener-mode control, conversation sends and delivery receipts."

  alias Aiur.Listener.{Effective, ModeStore, Receipt, SpecStatus}
  alias Aiur.TrackerIdentity

  @type target :: String.t() | TrackerIdentity.t()
  @type result :: {:ok, Effective.view()} | {:error, term()}

  @doc false
  @spec routing() :: :listener | :legacy
  @spec routing(keyword()) :: :listener | :legacy
  def routing(opts \\ []) do
    if Application.get_env(:aiur, :listener_send_routing, :listener) == :listener and Keyword.get_lazy(opts, :spec_status, &SpecStatus.read/0) == :ok,
      do: :listener,
      else: :legacy
  end

  @doc """
  Enqueue conversation text through the C1 send port: `send(target, text, opts)`.

  `target` is a ticket identifier or `%Aiur.TrackerIdentity{}`. The
  `ConversationRef` overload belongs to C6/MP-E3. The plan form
  `send(conversation_ref, text, client_request_id, opts)` maps its request ID
  to `opts[:client_request_id]`; this port currently takes three arguments.

  Options:

    * `:origin` — required in practice: `:agent_chat`, `:voice_assistant`,
      `:http` or `:tui`. An absent or unknown origin becomes `:internal`.
      With the default delivery policy, `:legacy` routing rejects `:internal`
      with `{:error, :invalid_message}`.
    * `:client_request_id` — optional identifier for one user action; reuse it
      when retrying. Without an identifier, every send queues a new item.
    * `:message_id` — compatibility alias for `:client_request_id`; an explicit
      `:client_request_id` takes precedence.
    * `:delivery_policy` — defaults to `:listener`; an explicit value wins.
    * `:correlation` — optional correlation map. A plain send retains it only
      when it contains `:native_ref`; other correlation maps are dropped.
    * `:actor` — optional actor attribution, such as `"device:<id>"`.
    * `:turn_id` — optional turn identifier.
    * `:fallback` — defaults to `:queue_next`; used by explicit interrupt
      delivery when interruption is unavailable. Listener routing resolves
      the origin's legacy policy or the effective listener mode.

  Returns `{:ok, request_id}` on acceptance. `request_id` is an integer usable
  with `receipt/2`, which reads `DeliveryTarget.read_snapshot/2`. Acceptance
  does not prove delivery or consumption.

  The same `:client_request_id`, target and text return the same `request_id`
  without queueing a second item. Reusing the identifier with different text
  or a different target returns `{:error, {:message_id_conflict, id}}`, where
  `id` identifies the existing queue item.

  Callers must handle `{:error, reason}`, including `:invalid_message`,
  `:no_running_agent` (unknown target), `:unavailable` (no orchestrator),
  `:listener_mode_unavailable`, `{:message_id_conflict, id}`,
  `{:not_queued, :timeout}` and `{:outcome_unknown, map}`. An unknown outcome
  may already have been enqueued; classify send results with
  `receipt_for_send_result/1` and reuse the request identifier on retry.
  """
  @spec send(target(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(target, text, opts \\ []) do
    origin = Keyword.get(opts, :origin, :internal)
    origin = if origin in [:agent_chat, :http, :tui, :voice_assistant, :internal], do: origin, else: :internal

    if valid_target?(target) and is_binary(text) do
      opts = opts |> Keyword.put(:origin, origin) |> Keyword.put_new(:delivery_policy, :listener)
      delivery_target().enqueue(target, text, opts)
    else
      {:error, :invalid_message}
    end
  end

  @spec get_mode(target()) :: result()
  def get_mode(target) do
    if valid_target?(target), do: delivery_target().get_mode(target), else: {:error, :invalid_target}
  end

  @doc "Set a mode with required expected_version; actor defaults to human. Reuse the idempotency key on retry."
  @spec set_mode(target(), ModeStore.mode(), keyword()) :: result()
  def set_mode(target, mode, opts) do
    cond do
      not valid_target?(target) -> {:error, :invalid_target}
      mode not in [:sync, :steer, :async] -> {:error, :invalid_mode}
      not (is_integer(opts[:expected_version]) and opts[:expected_version] >= 0) -> {:error, :invalid_expected_version}
      Keyword.get(opts, :actor, :human) not in [:human, :executor, :system] -> {:error, :invalid_actor}
      not (is_nil(opts[:idempotency_key]) or is_binary(opts[:idempotency_key])) -> {:error, :invalid_idempotency_key}
      true -> delivery_target().set_mode(target, mode, opts)
    end
  end

  @doc "Observe a request without treating a claim as provider confirmation."
  @spec receipt(integer(), timeout()) :: {:ok, Receipt.t()} | {:error, term()}
  def receipt(request_id, timeout \\ 5_000) when is_integer(request_id) do
    with {:ok, item} <- delivery_target().read_snapshot(request_id, timeout) do
      {:ok, Receipt.from_snapshot(item)}
    end
  end

  @doc "Classify send acceptance; a timed-out send may still have been enqueued."
  @spec receipt_for_send_result({:ok, term()} | {:error, term()}) :: :accepted | :failed | :outcome_unknown
  def receipt_for_send_result({:error, {:outcome_unknown, _}}), do: :outcome_unknown
  def receipt_for_send_result({:error, _}), do: :failed
  def receipt_for_send_result({:ok, _}), do: :accepted

  defp valid_target?(%TrackerIdentity{identifier: id}), do: is_binary(id) and id != ""
  defp valid_target?(id), do: is_binary(id) and id != ""
  defp delivery_target, do: Application.fetch_env!(:aiur, :listener_delivery_target)
end
