defmodule Aiur.OverlapReviewer do
  @moduledoc "Advisory repository overlap checks at dispatch, review, and periodic feature scans."

  use GenServer
  @behaviour Aiur.PeriodicWorker
  require Logger

  alias Aiur.{DecisionPubSub, Events, Instance, Issue, PeriodicWorker, Project, Tracker}
  alias Aiur.GitHub.{Access, AgentMarker, Config}
  alias Aiur.OverlapReviewer.{Corpus, Matcher, Report}
  alias Aiur.Project.Table

  @interval_ms 5 * 60_000
  @retry_ms 30_000
  @report_retention_ms 24 * 60 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, Project.carry(opts), name: Keyword.get_lazy(opts, :name, fn -> Project.via(__MODULE__) end))
  end

  @doc "Evaluates the latest repository snapshot before invoking the agent runner."
  @spec before_dispatch(Issue.t()) :: :ok
  def before_dispatch(%Issue{} = issue) do
    with table when not is_nil(table) <- Table.ref(__MODULE__),
         number when is_integer(number) <- Corpus.number(issue.identifier) do
      subject = Matcher.document(:issue, number, issue.title, issue.description)
      review = assess(subject, current_corpus(table))
      GenServer.cast(Project.via(__MODULE__), {:verdict, :dispatch, number, review})
    else
      _ -> :ok
    end
  rescue
    # The advisory table can disappear during a project restart.
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    Project.adopt(opts)
    interval_ms = Keyword.get(opts, :interval_ms, Application.get_env(:aiur, :executor_sweep_interval_ms, @interval_ms))
    enabled? = interval_ms > 0
    table = if enabled?, do: Table.new(__MODULE__, [:protected, :set, read_concurrency: true])
    if enabled?, do: DecisionPubSub.subscribe_creator_overlap()
    if enabled? and Keyword.get(opts, :subscribe?, true), do: subscribe()
    if enabled? and Keyword.get(opts, :start_immediately?, true), do: send(self(), :tick)

    {:ok,
     %{
       table: table,
       enabled?: enabled?,
       interval_ms: max(interval_ms, 1),
       capture: Keyword.get(opts, :capture, &Corpus.capture/0),
       memberships: Keyword.get(opts, :memberships, &Corpus.memberships/0),
       wake: Keyword.get(opts, :wake, &Report.wake/1),
       comment: Keyword.get(opts, :comment, &publish_comment/2),
       reports: %{},
       pending_comments: %{},
       feature_reports: MapSet.new()
     }}
  end

  @impl Aiur.PeriodicWorker
  def tick(state) do
    state = state |> prune_reports() |> retry_comments()

    case state.capture.() do
      {:ok, corpus} ->
        :ets.insert(state.table, {:corpus, corpus})
        state |> Map.put(:next_delay_ms, state.interval_ms) |> scan_features(corpus)

      {:error, _reason} ->
        Map.put(state, :next_delay_ms, @retry_ms)
    end
  end

  @impl GenServer
  def handle_cast({:verdict, phase, ticket, review}, state) do
    {:noreply, report_verdict(state, phase, ticket, review)}
  end

  @impl GenServer
  def handle_info({:creator_overlap, identifier, %{command_path: path, status: status}}, %{enabled?: true} = state) do
    case Corpus.number(identifier) do
      nil -> {:noreply, state}
      number -> {:noreply, report_once(state, {:command, number, path, status}, Report.command(number, path, status), false)}
    end
  end

  def handle_info({:event, %{topic: "ticket." <> suffix} = event}, %{enabled?: true} = state) do
    with [id, "pr", action] <- String.split(suffix, "."),
         ticket when is_integer(ticket) <- Corpus.number(id),
         true <- review_round?(action, event),
         false <- Instance.skip?(id, nil, :overlap_review) do
      corpus = current_corpus(state.table)
      {:noreply, report_verdict(state, :review, ticket, review_verdict(corpus, ticket, event))}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(:tick, %{enabled?: true} = state) do
    state = PeriodicWorker.run_tick(__MODULE__, state)
    PeriodicWorker.schedule_tick(Map.get(state, :next_delay_ms, state.interval_ms))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe do
    Events.subscribe("ticket.*.pr.ready_for_review")
    Events.subscribe("ticket.*.pr.review_comment")
  end

  defp review_round?("ready_for_review", _event), do: true

  defp review_round?("review_comment", event) do
    comment = event[:comment] || event["comment"] || %{}
    (event[:author_trusted?] || event["author_trusted?"]) == true and is_binary(comment["state"])
  end

  defp review_round?(_action, _event), do: false

  defp review_verdict(nil, _ticket, _event), do: assess(nil, nil)

  defp review_verdict(corpus, ticket, event) do
    issue = corpus.issues[ticket]

    case assess(review_subject(corpus, ticket, event), corpus) do
      %{action: action} when action in [:build, :unavailable] and is_map(issue) -> assess(issue, corpus)
      verdict -> verdict
    end
  end

  defp review_subject(corpus, ticket, event) do
    {pr, number, head_sha} = review_target(event)
    key = Access.key_for_repo(:pull_request, corpus.repo, number)

    document =
      case Enum.find([pr, Access.data(key)], &matching_head?(&1, number, head_sha)) do
        nil -> pull_at_head(corpus.pulls[number], head_sha)
        raw -> Corpus.pull_document(raw, corpus.repo)
      end

    if document, do: %{document | ticket_numbers: Enum.uniq([ticket | document.ticket_numbers])}
  end

  defp review_target(event) do
    pr = event[:pr] || event[:pull_request] || event["pull_request"] || %{}
    comment = event[:comment] || event["comment"] || %{}
    number = Corpus.number(pr["number"]) || review_url_number(comment["html_url"])
    head_sha = get_in(pr, ["head", "sha"]) || comment["commit_id"]
    {pr, number, head_sha}
  end

  defp matching_head?(%{"number" => number, "title" => title} = raw, number, sha) when is_binary(title),
    do: is_nil(sha) or get_in(raw, ["head", "sha"]) == sha

  defp matching_head?(_raw, _number, _sha), do: false

  defp pull_at_head(%{head_sha: sha} = document, sha), do: document
  defp pull_at_head(document, nil), do: document
  defp pull_at_head(_document, _sha), do: nil

  defp review_url_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)(?:[/#?]|$)}, url, capture: :all_but_first) do
      [id] -> Corpus.number(id)
      _ -> nil
    end
  end

  defp review_url_number(_), do: nil

  defp current_corpus(table) do
    previous =
      case :ets.lookup(table, :corpus) do
        [{:corpus, corpus}] -> if Corpus.current?(corpus, System.system_time(:millisecond)), do: corpus
        [] -> nil
      end

    Corpus.cached(previous)
  end

  defp assess(subject, corpus) when is_map(subject) and is_map(corpus), do: Matcher.review(subject, corpus.documents)
  defp assess(_subject, _corpus), do: %{action: :unavailable, evidence: %{}}

  defp report_verdict(state, phase, ticket, review) do
    finding = Report.verdict(ticket, phase, review)
    report_once(state, {phase, ticket}, finding, review.action != :unavailable)
  end

  # Emit on a changed recommendation or changed evidence. Retries and repeated
  # review submissions with the same result leave one ticket note and wake.
  defp report_once(state, key, finding, comment?) do
    case state.reports[key] do
      {same, _} when same == finding.message ->
        state

      _ ->
        publish_wake(state, finding)
        state = %{state | reports: Map.put(state.reports, key, {finding.message, System.monotonic_time(:millisecond)})}

        if comment?, do: save_comment(state, key, finding.ticket, Report.comment(finding)), else: state
    end
  end

  defp save_comment(state, key, ticket, body) do
    pending =
      case state.comment.(ticket, body) do
        :ok -> Map.delete(state.pending_comments, key)
        {:error, _reason} -> Map.put(state.pending_comments, key, {ticket, body})
      end

    %{state | pending_comments: pending}
  end

  defp retry_comments(state) do
    Enum.reduce(state.pending_comments, state, fn {key, {ticket, body}}, acc -> save_comment(acc, key, ticket, body) end)
  end

  defp prune_reports(state) do
    cutoff = System.monotonic_time(:millisecond) - @report_retention_ms
    reports = Map.reject(state.reports, fn {_key, {_message, seen_at}} -> seen_at < cutoff end)
    %{state | reports: reports, pending_comments: Map.take(state.pending_comments, Map.keys(reports))}
  end

  defp scan_features(state, corpus) do
    case state.memberships.() do
      {:ok, memberships} ->
        findings = corpus.documents |> Matcher.feature_scan(memberships) |> Enum.map(&Report.feature/1) |> MapSet.new()
        findings |> MapSet.difference(state.feature_reports) |> Enum.each(&publish_wake(state, &1))
        %{state | feature_reports: findings}

      :unavailable ->
        state
    end
  end

  defp publish_wake(state, finding), do: state.wake.(Map.put(finding, :repository, Config.repo()))

  defp publish_comment(ticket, body) do
    ticket = Integer.to_string(ticket)

    with {:ok, comments} <- Tracker.fetch_classified_issue_comments(ticket),
         false <- Enum.any?(comments, &(comment_body(&1) == body)),
         :ok <- Tracker.create_comment(ticket, body) do
      :ok
    else
      true ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Overlap review note could not be written for ##{ticket}: #{inspect(reason)}")
        error
    end
  end

  # In single-account mode the writer appends an authorship marker.
  defp comment_body(comment), do: (comment[:body] || comment["body"] || "") |> String.trim_trailing(AgentMarker.marker()) |> String.trim()
end
