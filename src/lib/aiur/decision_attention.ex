defmodule Aiur.DecisionAttention do
  @moduledoc """
  Turns open agent attentions into durable operator-decision alerts.

  Agent events are ephemeral exchange messages, while `aiurdev watch` and the
  real-time alert relay read structured alert entries. This registry bridges
  the two and keeps an unanswered question visible with bounded re-asks.
  """

  use GenServer

  alias Aiur.{Alerts, Issue}
  alias Aiur.Events.SubscriptionStore

  @default_reask_interval_ms :timer.minutes(15)

  @type attention :: %{
          issue: Issue.t(),
          workspace: Path.t() | nil,
          worker_host: String.t() | nil,
          slug: String.t(),
          question: String.t(),
          timer_ref: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open(Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) :: :ok
  def open(issue, workspace, worker_host, slug, question) do
    open(__MODULE__, issue, workspace, worker_host, slug, question)
  end

  @spec open(GenServer.server(), Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) :: :ok
  def open(server, %Issue{} = issue, workspace, worker_host, slug, question)
      when is_binary(slug) and is_binary(question) do
    GenServer.call(server, {:open, issue, workspace, worker_host, slug, question})
  end

  @spec resolve(Issue.t(), String.t()) :: :ok
  def resolve(issue, slug), do: resolve(__MODULE__, issue, slug)

  @spec resolve(GenServer.server(), Issue.t(), String.t()) :: :ok
  def resolve(server, %Issue{} = issue, slug) when is_binary(slug) do
    GenServer.call(server, {:resolve, issue, slug})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       attentions: %{},
       reask_interval_ms: Keyword.get(opts, :reask_interval_ms, @default_reask_interval_ms),
       alert_emitter: Keyword.get(opts, :alert_emitter, &emit_alert/1),
       resolution_emitter: Keyword.get(opts, :resolution_emitter, &emit_resolution_alert/1)
     }}
  end

  @impl true
  def handle_call({:open, issue, workspace, worker_host, slug, question}, _from, state) do
    identifier = issue_identifier!(issue)
    key = {identifier, slug}
    cancel_timer(Map.get(state.attentions, key))

    attention = %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      slug: slug,
      question: question,
      timer_ref: nil
    }

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, slug)
    emit(state.alert_emitter, attention)

    next_attention = schedule_reask(attention, state.reask_interval_ms)
    {:reply, :ok, %{state | attentions: Map.put(state.attentions, key, next_attention)}}
  end

  def handle_call({:resolve, issue, slug}, _from, state) do
    identifier = issue_identifier!(issue)
    key = {identifier, slug}
    attention = Map.get(state.attentions, key) || %{}
    cancel_timer(attention)

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.resolve_attention(identifier, slug)

    state.resolution_emitter.(%{
      issue: issue,
      workspace: Map.get(attention, :workspace),
      worker_host: Map.get(attention, :worker_host),
      slug: slug
    })

    {:reply, :ok, %{state | attentions: Map.delete(state.attentions, key)}}
  end

  @impl true
  def handle_info({:reask, key}, state) do
    case Map.get(state.attentions, key) do
      nil ->
        {:noreply, state}

      attention ->
        emit(state.alert_emitter, attention)
        next_attention = schedule_reask(attention, state.reask_interval_ms)
        {:noreply, %{state | attentions: Map.put(state.attentions, key, next_attention)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_reask(attention, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    timer_ref = Process.send_after(self(), {:reask, attention_key(attention)}, interval_ms)
    %{attention | timer_ref: timer_ref}
  end

  defp schedule_reask(attention, _interval_ms), do: attention

  defp emit(alert_emitter, attention), do: alert_emitter.(attention)

  defp emit_alert(attention) do
    Alerts.emit_system(attention_topic(attention),
      issue: attention.issue,
      workspace: attention.workspace,
      worker_host: attention.worker_host,
      reason: "Operator decision required: #{attention.question}",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_resolution_alert(attention) do
    Alerts.emit_custom(resolution_topic(attention), "Operator decision updated",
      issue: attention.issue,
      workspace: attention.workspace,
      worker_host: attention.worker_host,
      reason: "Operator decision resolved.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp attention_topic(attention), do: "ticket.#{issue_identifier!(attention.issue)}.agent.attention.#{attention.slug}"
  defp resolution_topic(attention), do: attention_topic(attention) <> ".resolved"
  defp attention_key(attention), do: {issue_identifier!(attention.issue), attention.slug}

  defp issue_identifier!(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp issue_identifier!(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier

  defp cancel_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_timer(_attention), do: :ok
end
