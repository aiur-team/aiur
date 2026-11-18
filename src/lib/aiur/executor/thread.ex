defmodule Aiur.Executor.Thread do
  @moduledoc """
  The operator↔Executor thread as a host app sees it: one conversation with
  operator and Executor messages, and a send that never drops a message.

  Reads come from the Executor conversation journal, so a message appears once
  the Executor session records it. A send goes through the listener delivery
  port. With no live Executor the message still queues for the next attached
  session and records a wake, so `aiur executor-wait` sees it.
  """

  alias Aiur.Conversation.{History, Ref}
  alias Aiur.Executor.{Send, Session}
  alias Aiur.Listener

  @kinds ["message", "operator_message"]
  @queueable [:not_attached, :executor_unreachable]

  @type message :: %{
          id: String.t(),
          pos: pos_integer() | nil,
          request_id: integer() | nil,
          role: String.t(),
          text: String.t(),
          attachments: [map()],
          created_at: String.t() | nil,
          delivery: String.t() | nil
        }

  @doc "Whether the thread exists, whether an Executor is attached and live, and whether a send is accepted."
  @spec info(keyword()) :: map()
  def info(opts \\ []) do
    capability = capability(opts)

    %{
      conversation_id: conversation_id(),
      executor: executor(opts),
      can_send: can_send(capability)
    }
  end

  @doc """
  Operator and Executor messages after journal position `after`, oldest first.
  `next_after` is the position to pass next; it stays put when nothing is new.
  """
  @spec messages(non_neg_integer(), pos_integer(), term()) :: {:ok, %{messages: [message()], next_after: non_neg_integer()}} | {:error, atom()}
  def messages(after_pos, limit, principal) do
    case History.list_entries(Ref.executor(), after: after_pos, limit: limit, kinds: @kinds, principal: principal) do
      {:ok, page} ->
        {:ok, %{messages: Enum.flat_map(page.entries, &message/1), next_after: next_after(page, after_pos)}}

      {:error, :not_found} ->
        {:ok, %{messages: [], next_after: after_pos}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Sends operator text to the Executor. A repeat `client_request_id` with the
  same text returns the same message. Without a live Executor the message is
  queued for the next attached session and a wake is recorded.
  """
  @spec send(String.t(), String.t(), keyword()) :: {:ok, message()} | {:error, term()}
  def send(text, client_request_id, opts \\ []) do
    case capability(opts) do
      :available -> enqueue(text, client_request_id, opts, false)
      {:unavailable, reason} when reason in @queueable -> enqueue(text, client_request_id, opts, true)
      {:unavailable, reason} -> {:error, {:executor_unavailable, reason}}
    end
  end

  # `Send.capability/1` reports a missing session before it checks delivery
  # support and read-only mode; a queued send must pass those too.
  defp capability(opts) do
    cond do
      not Keyword.get(opts, :delivery_fun, &Listener.executor_delivery_installed?/0).() -> {:unavailable, :executor_delivery_not_installed}
      not Keyword.get_lazy(opts, :writable, &Aiur.Config.dashboard_writable?/0) -> {:unavailable, :read_only}
      true -> Send.capability(opts)
    end
  end

  defp enqueue(text, client_request_id, opts, wake?) do
    send_fun = Keyword.get(opts, :listener_send_fun, &Listener.send/3)

    case send_fun.(Ref.executor(), text, origin: :http, client_request_id: client_request_id) do
      {:ok, request_id} ->
        if wake?, do: record_wake(request_id, opts)
        {:ok, sent(request_id, text, "queued")}

      {:error, {:outcome_unknown, _detail}} ->
        {:ok, sent(nil, text, "outcome_unknown")}

      {:error, _reason} = error ->
        error
    end
  end

  defp record_wake(request_id, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record = %{
      "event_id" => nil,
      "topic" => "executor.thread.message",
      "topic_class" => "executor.thread",
      "ticket" => nil,
      "action" => "operator_message",
      "request_id" => request_id,
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }

    Keyword.get(opts, :wake_fun, &Aiur.ExecutorWakeInbox.enqueue/1).(record)
  catch
    :exit, _reason -> :ok
  end

  defp sent(request_id, text, delivery) do
    %{
      id: if(request_id, do: "req_#{request_id}", else: "req_unknown"),
      pos: nil,
      request_id: request_id,
      role: "operator",
      text: text,
      attachments: [],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      delivery: delivery
    }
  end

  defp message(%{kind: kind, role: role, pos: pos} = entry) when kind in @kinds do
    case thread_role(kind, role) do
      nil ->
        []

      thread_role ->
        [
          %{
            id: "pos_#{pos}",
            pos: pos,
            request_id: delivery_id(entry),
            role: thread_role,
            text: Map.get(entry, :body) || "",
            attachments: [],
            created_at: timestamp(Map.get(entry, :occurred_at) || Map.get(entry, :observed_at)),
            delivery: if(thread_role == "operator", do: "delivered")
          }
        ]
    end
  end

  defp message(_entry), do: []

  defp thread_role("message", "agent"), do: "executor"
  defp thread_role("operator_message", role) when role in ["executor_operator", "operator"], do: "operator"
  defp thread_role(_kind, _role), do: nil

  defp delivery_id(entry) do
    case get_in(entry, [:refs, :delivery_id]) || get_in(entry, [:refs, "delivery_id"]) do
      id when is_integer(id) -> id
      id when is_binary(id) -> parse_int(id)
      _ -> nil
    end
  end

  defp parse_int(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp timestamp(at) when is_binary(at), do: at
  defp timestamp(_at), do: nil

  defp next_after(%{entries: []}, after_pos), do: after_pos
  defp next_after(%{entries: entries}, after_pos), do: max(after_pos, entries |> Enum.map(& &1.pos) |> Enum.max())

  defp conversation_id, do: Ref.conversation_id(Ref.executor())

  defp executor(opts) do
    case Keyword.get(opts, :binding_fun, &Session.current/0).() do
      {:ok, %{state: "attached"} = binding} -> %{attached: true, live: Map.get(binding, :live?) == true}
      _ -> %{attached: false, live: false}
    end
  catch
    :exit, _reason -> %{attached: false, live: false}
  end

  defp can_send(:available), do: true
  defp can_send({:unavailable, reason}) when reason in @queueable, do: true
  defp can_send({:unavailable, reason}), do: %{reason: Atom.to_string(reason)}
end
