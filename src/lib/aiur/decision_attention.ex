defmodule Aiur.DecisionAttention do
  @moduledoc """
  Turns open agent attentions into durable Executor-decision alerts.

  Agent events are ephemeral exchange messages, while `aiurdev watch` and the
  real-time alert relay read structured alert entries. This registry bridges
  the two and keeps an unanswered question visible with bounded re-asks.
  """

  use GenServer

  require Logger

  alias Aiur.{AlertFeed, Alerts, DecisionStore, Issue}
  alias Aiur.Events.SubscriptionStore

  @default_reask_interval_ms :timer.minutes(15)
  @default_import_limit 100
  # The outer registry call must outlast DecisionStore's 60-second write call
  # so the caller cannot time out while the registry later opens the alert.
  @open_timeout 65_000

  @type attention :: %{
          issue: Issue.t(),
          workspace: Path.t() | nil,
          worker_host: String.t() | nil,
          slug: String.t(),
          question: String.t(),
          timer_ref: reference() | nil
        }

  @type accept_result :: %{status: :accepted | :duplicate, decision: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open(Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) :: :ok | {:error, term()}
  def open(issue, workspace, worker_host, slug, question) do
    open(__MODULE__, issue, workspace, worker_host, slug, question)
  end

  @spec open(GenServer.server(), Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) ::
          :ok | {:error, term()}
  def open(server, %Issue{} = issue, workspace, worker_host, slug, question)
      when is_binary(slug) and is_binary(question) do
    case open_with_decision(server, issue, workspace, worker_host, slug, question, []) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Projects a reminder whose canonical parent fact was already persisted elsewhere."
  @spec open_persisted(Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) :: :ok
  def open_persisted(issue, workspace, worker_host, slug, question) do
    open_persisted(__MODULE__, issue, workspace, worker_host, slug, question)
  end

  @spec open_persisted(GenServer.server(), Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t()) :: :ok
  def open_persisted(server, %Issue{} = issue, workspace, worker_host, slug, question)
      when is_binary(slug) and is_binary(question) do
    GenServer.call(server, {:open_persisted, issue, workspace, worker_host, slug, question}, @open_timeout)
  end

  @spec open_with_decision(
          Issue.t(),
          Path.t() | nil,
          String.t() | nil,
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, accept_result()} | {:error, term()}
  def open_with_decision(%Issue{} = issue, workspace, worker_host, slug, question, opts)
      when is_binary(slug) and is_binary(question) and is_list(opts) do
    open_with_decision(__MODULE__, issue, workspace, worker_host, slug, question, opts)
  end

  @spec open_with_decision(
          GenServer.server(),
          Issue.t(),
          Path.t() | nil,
          String.t() | nil,
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, accept_result()} | {:error, term()}
  def open_with_decision(server, %Issue{} = issue, workspace, worker_host, slug, question, opts)
      when is_binary(slug) and is_binary(question) and is_list(opts) do
    GenServer.call(server, {:open, issue, workspace, worker_host, slug, question, opts}, @open_timeout)
  end

  @doc "Trusted correlation material shared by legacy projection and structured enrichment."
  @spec correlation(Issue.t(), String.t()) ::
          {:ok, %{source_id: String.t(), legacy_attention: map()}} | {:error, term()}
  def correlation(%Issue{} = issue, slug) when is_binary(slug) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug) do
      identifier = issue_identifier!(issue)

      {:ok,
       %{
         source_id: "legacy_attention:#{slug}",
         legacy_attention: %{
           slug: slug,
           topic: "ticket.#{identifier}.agent.attention.#{slug}"
         }
       }}
    else
      {:error, {:legacy_attention_slug, :invalid_format}}
    end
  end

  @spec resolve(Issue.t(), String.t()) :: :ok
  def resolve(issue, slug), do: resolve(__MODULE__, issue, slug)

  @spec resolve(GenServer.server(), Issue.t(), String.t()) :: :ok
  def resolve(server, %Issue{} = issue, slug) when is_binary(slug) do
    GenServer.call(server, {:resolve, issue, slug}, @open_timeout)
  end

  @impl true
  def init(opts) do
    state = %{
      attentions: %{},
      reask_interval_ms: Keyword.get(opts, :reask_interval_ms, @default_reask_interval_ms),
      alert_emitter: Keyword.get(opts, :alert_emitter, &emit_alert/1),
      resolution_emitter: Keyword.get(opts, :resolution_emitter, &emit_resolution_alert/1),
      attention_loader: Keyword.get(opts, :attention_loader, &AlertFeed.list_decision_attentions/0),
      decision_projector: Keyword.get(opts, :decision_projector, &DecisionStore.project_attention/2),
      import_limit: import_limit(opts),
      importing?: true,
      resolved_during_import: MapSet.new()
    }

    load_attentions_async(state.attention_loader)
    {:ok, state}
  end

  @impl true
  def handle_call({:open, issue, workspace, worker_host, slug, question, opts}, _from, state) do
    identifier = issue_identifier!(issue)
    key = {identifier, slug}

    attention = %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      slug: slug,
      question: question,
      timer_ref: nil
    }

    case project_attention(state.decision_projector, attention, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, register_attention(state, identifier, key, attention)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:open_persisted, issue, workspace, worker_host, slug, question}, _from, state) do
    identifier = issue_identifier!(issue)
    key = {identifier, slug}

    attention = %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      slug: slug,
      question: question,
      timer_ref: nil
    }

    {:reply, :ok, register_attention(state, identifier, key, attention)}
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

    resolved_during_import =
      if state.importing? do
        MapSet.put(state.resolved_during_import, key)
      else
        state.resolved_during_import
      end

    {:reply, :ok,
     %{
       state
       | attentions: Map.delete(state.attentions, key),
         resolved_during_import: resolved_during_import
     }}
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

  def handle_info({:legacy_attentions_loaded, attentions}, state) when is_list(attentions) do
    {to_import, ignored} = Enum.split(attentions, state.import_limit)

    if ignored != [] do
      Logger.warning(
        "decision_attention legacy_import_truncated " <>
          "limit=#{state.import_limit} ignored_count=#{length(ignored)}"
      )
    end

    Enum.each(to_import, &send(self(), {:restore_attention, &1}))
    send(self(), :legacy_attention_import_complete)
    {:noreply, state}
  end

  def handle_info({:restore_attention, attention}, state) do
    {:noreply, restore_attention(attention, state)}
  end

  def handle_info(:legacy_attention_import_complete, state) do
    {:noreply, %{state | importing?: false, resolved_during_import: MapSet.new()}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_reask(attention, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    timer_ref = Process.send_after(self(), {:reask, attention_key(attention)}, interval_ms)
    %{attention | timer_ref: timer_ref}
  end

  defp schedule_reask(attention, _interval_ms), do: attention

  defp register_attention(state, identifier, key, attention) do
    cancel_timer(Map.get(state.attentions, key))
    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, attention.slug)
    emit(state.alert_emitter, attention)

    next_attention = schedule_reask(attention, state.reask_interval_ms)

    %{
      state
      | attentions: Map.put(state.attentions, key, next_attention),
        resolved_during_import: MapSet.delete(state.resolved_during_import, key)
    }
  end

  defp emit(alert_emitter, attention), do: alert_emitter.(attention)

  defp project_attention(projector, attention, opts) do
    with {:ok, correlation} <- correlation(attention.issue, attention.slug) do
      payload =
        %{
          "source_id" => correlation.source_id,
          "kind" => "legacy_attention",
          "question" => attention.question,
          "blocking" => true,
          "options" => []
        }
        |> maybe_put_source_created_at(Keyword.get(opts, :source_created_at))

      projector_opts = [
        ticket: ticket_context(attention.issue),
        source: Keyword.get(opts, :source, %{}),
        legacy_attention: correlation.legacy_attention,
        legacy_import: Keyword.get(opts, :legacy_import, false)
      ]

      safely_project(projector, payload, projector_opts)
    end
  end

  defp safely_project(projector, payload, opts) do
    projector.(payload, opts)
  catch
    :exit, reason -> {:error, {:decision_store_exit, reason}}
  end

  defp load_attentions_async(loader) do
    owner = self()

    {:ok, _pid} =
      Task.start(fn ->
        send(owner, {:legacy_attentions_loaded, safely_load_attentions(loader)})
      end)

    :ok
  end

  defp safely_load_attentions(loader) do
    case loader.() do
      attentions when is_list(attentions) ->
        attentions

      _other ->
        Logger.warning("decision_attention legacy_import_failed reason=invalid_loader_result")
        []
    end
  rescue
    error ->
      Logger.warning("decision_attention legacy_import_failed reason=#{inspect(Exception.message(error))}")
      []
  catch
    kind, reason ->
      Logger.warning("decision_attention legacy_import_failed reason=#{inspect({kind, reason})}")
      []
  end

  defp restore_attention(
         %{
           identifier: identifier,
           slug: slug,
           question: question,
           source_created_at: source_created_at
         },
         state
       ) do
    key = {identifier, slug}

    if Map.has_key?(state.attentions, key) or MapSet.member?(state.resolved_during_import, key) do
      state
    else
      restore_missing_attention(identifier, slug, question, source_created_at, key, state)
    end
  end

  defp restore_attention(_invalid, state), do: state

  defp restore_missing_attention(identifier, slug, question, source_created_at, key, state) do
    issue = %Issue{identifier: identifier}

    attention = %{
      issue: issue,
      workspace: nil,
      worker_host: nil,
      slug: slug,
      question: question,
      timer_ref: nil
    }

    opts = [
      source: %{agent_id: "legacy_attention", session_id: nil, event_id: nil},
      source_created_at: source_created_at,
      legacy_import: true
    ]

    case project_attention(state.decision_projector, attention, opts) do
      {:ok, _result} ->
        :ok = SubscriptionStore.attach(identifier)
        :ok = SubscriptionStore.add_attention(identifier, slug)
        next_attention = schedule_reask(attention, state.reask_interval_ms)
        %{state | attentions: Map.put(state.attentions, key, next_attention)}

      {:error, reason} ->
        Logger.warning("decision_attention legacy_import_rejected issue_identifier=#{identifier} slug=#{slug} reason=#{inspect(reason)}")

        state
    end
  end

  defp maybe_put_source_created_at(payload, %DateTime{} = source_created_at) do
    Map.put(payload, "created_at", DateTime.to_iso8601(source_created_at))
  end

  defp maybe_put_source_created_at(payload, _source_created_at), do: payload

  defp ticket_context(issue) do
    %{
      identifier: issue_identifier!(issue),
      title: issue.title,
      url: issue.url
    }
  end

  defp emit_alert(attention) do
    Alerts.emit_system(attention_topic(attention),
      issue: attention.issue,
      workspace: attention.workspace,
      worker_host: attention.worker_host,
      reason: "Executor decision required: #{attention.question}",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_resolution_alert(attention) do
    Alerts.emit_custom(resolution_topic(attention), "Executor decision updated",
      issue: attention.issue,
      workspace: attention.workspace,
      worker_host: attention.worker_host,
      reason: "Executor decision resolved.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp attention_topic(attention), do: "ticket.#{issue_identifier!(attention.issue)}.agent.attention.#{attention.slug}"
  defp resolution_topic(attention), do: attention_topic(attention) <> ".resolved"
  defp attention_key(attention), do: {issue_identifier!(attention.issue), attention.slug}

  defp issue_identifier!(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp issue_identifier!(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier

  defp import_limit(opts) do
    case Keyword.get(opts, :import_limit, @default_import_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_import_limit
    end
  end

  defp cancel_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_timer(_attention), do: :ok
end
