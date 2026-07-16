defmodule AiurWeb.OperatorControlCenter.UnitsRow do
  @moduledoc """
  Pure, provenance-rich projection for one current-run Units snapshot.

  Membership defines which rows exist. Every cross-source lookup uses the
  repository-qualified `TrackerIdentity` key, never a display identifier.
  """

  alias Aiur.{Issue, TrackerIdentity}

  @version 1
  @blocking_reasons [:waiting_for_human, :waiting_for_supervisor, :waiting_for_dependency, :waiting_for_ci, :waiting_for_review]

  @spec version() :: pos_integer()
  def version, do: @version

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    membership = source(inputs, :membership)
    status = source(inputs, :status)
    activity = source(inputs, :activity)
    decisions = source(inputs, :decisions)
    facts = source(inputs, :issue_facts)

    status_rows = status_index(status)
    activity_rows = identity_index(entries(activity))
    decision_rows = identity_index(entries(decisions))
    issue_facts = identity_index(entries(facts))

    rows =
      membership
      |> entries()
      |> Enum.flat_map(fn member ->
        case identity(member) do
          %TrackerIdentity{} = identity ->
            if TrackerIdentity.joinable?(identity) do
              [
                row(
                  member,
                  identity,
                  Map.get(status_rows, key(identity)),
                  Map.get(activity_rows, key(identity)),
                  Map.get(decision_rows, key(identity)),
                  Map.get(issue_facts, key(identity)),
                  membership,
                  status,
                  activity,
                  decisions,
                  facts
                )
              ]
            else
              []
            end

          _identity ->
            []
        end
      end)
      |> Enum.sort_by(&key(&1.identity))

    %{
      version: @version,
      generation: source_generations(membership, status, activity, decisions, facts),
      health: source_health(membership, status, activity, decisions, facts),
      freshness: source_freshness(membership, status, activity, decisions, facts),
      truncated?: field(membership, :truncated?) == true,
      rows: rows
    }
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec lookup([map()] | map(), TrackerIdentity.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(%{rows: rows}, identity), do: lookup(rows, identity)

  def lookup(rows, %TrackerIdentity{} = identity) when is_list(rows) do
    case Enum.find(rows, &(key(Map.get(&1, :identity)) == key(identity))) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def lookup(_rows, _identity), do: {:error, :not_found}

  defp row(member, identity, status_row, activity_row, decision_row, issue_fact, membership, status, activity, decisions, facts) do
    replacement_boundary? = replacement_boundary?(status_row)
    terminal? = Map.get(member, :terminal?) == true and not replacement_boundary?
    lifecycle = if replacement_boundary?, do: :waiting, else: Map.get(member, :lifecycle)
    {title, title_source} = sourced_value(issue_fact, status_row, [:title])
    {url, url_source} = sourced_value(issue_fact, status_row, [:url])
    {tracker_state, state_source} = sourced_value(issue_fact, status_row, [:state])
    {backend, backend_source} = sourced_value(issue_fact, status_row, [:backend, :selected_backend])
    {agent_family, agent_family_source} = sourced_value(issue_fact, status_row, [:agent_family])
    {requested_model, requested_model_source} = sourced_value(issue_fact, status_row, [:requested_model])
    {resolved_model, resolved_model_source} = sourced_value(issue_fact, status_row, [:resolved_model])
    {effort, effort_source} = sourced_value(issue_fact, status_row, [:effort])
    {complexity, complexity_source} = sourced_complexity(issue_fact, status_row)
    {build_lane, build_lane_source} = sourced_build_lane(issue_fact, status_row)

    %{
      identity: identity,
      title: title,
      url: normalize_url(url, identity),
      lifecycle: lifecycle,
      terminal?: terminal?,
      replacement_boundary?: replacement_boundary?,
      tracker_state: tracker_state,
      backend: backend,
      agent_family: agent_family,
      requested_model: requested_model,
      resolved_model: resolved_model,
      effort: effort,
      complexity: complexity,
      build_lane: build_lane,
      reasons: reasons(status_row, decision_row),
      runtime: runtime(status_row, member),
      timestamps: %{
        first_observed_at: Map.get(member, :first_observed_at),
        last_observed_at: Map.get(member, :last_observed_at),
        started_at: field(status_row, :started_at),
        last_activity_at: field(status_row, :last_codex_timestamp) || field(status_row, :last_event_at)
      },
      open_command_count: decision_count(decision_row, status_row),
      progress: activity_value(activity_row, :progress),
      latest_evidence: activity_value(activity_row, :latest_evidence),
      provider_health: source_health(membership, status, activity, decisions, facts),
      field_sources: %{
        title: title_source,
        url: url_source,
        tracker_state: state_source,
        lifecycle: :membership,
        backend: backend_source,
        agent_family: agent_family_source,
        requested_model: requested_model_source,
        resolved_model: resolved_model_source,
        effort: effort_source,
        complexity: complexity_source,
        build_lane: build_lane_source,
        progress: if(is_nil(activity_row), do: :unknown, else: :activity),
        open_command_count: command_count_source(decision_row, status_row)
      },
      sources: %{
        membership: source_descriptor(membership, member),
        status: source_descriptor(status, status_row),
        activity: source_descriptor(activity, activity_row),
        decisions: source_descriptor(decisions, decision_row),
        issue: source_descriptor(facts, issue_fact)
      }
    }
  end

  defp source(inputs, key), do: Map.get(inputs, key) || Map.get(inputs, Atom.to_string(key)) || %{}

  defp entries(%{} = source) do
    case Map.get(source, :members) || Map.get(source, :entries) || Map.get(source, :rows) do
      rows when is_list(rows) -> rows
      _rows -> Map.get(source, :items, [])
    end
  end

  defp entries(rows) when is_list(rows), do: rows
  defp entries(_source), do: []

  defp status_index(snapshot) do
    [:idle, :retrying, :running]
    |> Enum.reduce(%{}, fn bucket, index ->
      snapshot
      |> field(bucket, [])
      |> List.wrap()
      |> Enum.reduce(index, fn entry, acc ->
        case identity(entry) do
          %TrackerIdentity{} = identity ->
            if TrackerIdentity.joinable?(identity), do: Map.put(acc, key(identity), Map.put(entry, :bucket, bucket)), else: acc

          _identity ->
            acc
        end
      end)
    end)
  end

  defp identity_index(rows) do
    Enum.reduce(rows, %{}, fn entry, index ->
      case identity(entry) do
        %TrackerIdentity{} = identity -> if TrackerIdentity.joinable?(identity), do: Map.put(index, key(identity), entry), else: index
        _identity -> index
      end
    end)
  end

  defp identity(%Issue{} = issue), do: Issue.tracker_identity(issue)
  defp identity(%{} = value), do: Map.get(value, :identity) || Map.get(value, :tracker_identity)
  defp identity(_value), do: nil

  defp key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  defp key(_identity), do: nil

  defp replacement_boundary?(status_row) do
    field(status_row, :work_state) == :completed and field(status_row, :waiting_reason) == :awaiting_dispatch
  end

  defp sourced_value(issue_fact, status_row, keys) do
    Enum.find_value([{:canonical_issue, issue_fact}, {:status_report, status_row}], {nil, :unknown}, fn {source, value} ->
      Enum.find_value(keys, fn key ->
        if present?(field(value, key)), do: {field(value, key), source}
      end)
    end)
  end

  defp sourced_complexity(issue_fact, status_row) do
    sourced_derived_value(issue_fact, status_row, &complexity/1)
  end

  defp sourced_build_lane(issue_fact, status_row) do
    sourced_derived_value(issue_fact, status_row, &build_lane/1)
  end

  defp sourced_derived_value(issue_fact, status_row, value_fun) do
    Enum.find_value([{:canonical_issue, issue_fact}, {:status_report, status_row}], {nil, :unknown}, fn {source, value} ->
      case value_fun.(value) do
        nil -> nil
        derived -> {derived, source}
      end
    end)
  end

  defp complexity(issue) do
    case field(issue, :complexity) do
      value when is_integer(value) and value > 0 -> value
      _value -> label_value(issue, "complexity:", &parse_positive_integer/1)
    end
  end

  defp build_lane(issue) do
    field(issue, :build_lane) || label_value(issue, "build-lane:", &normalize_nonempty/1)
  end

  defp label_value(issue, prefix, parser) do
    issue
    |> field(:labels, [])
    |> List.wrap()
    |> Enum.find_value(fn
      label when is_binary(label) ->
        case String.split(label, prefix, parts: 2) do
          ["", value] -> parser.(value)
          _parts -> nil
        end

      _label ->
        nil
    end)
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _value -> nil
    end
  end

  defp normalize_nonempty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      lane -> lane
    end
  end

  defp normalize_nonempty(_value), do: nil

  defp reasons(status_row, decision_row) do
    waiting = field(status_row, :waiting_reason)
    pause = field(status_row, :pause_reason)
    explicit_alert = field(status_row, :alert_reason)
    count = decision_count(decision_row, status_row)

    %{
      waiting: waiting,
      blocking: field(status_row, :blocking_reason) || if(waiting in @blocking_reasons, do: waiting),
      alert: explicit_alert || if(is_integer(count) and count > 0, do: :open_command),
      pause: pause || if(field(status_row, :tracker_paused) == true, do: :tracker_paused),
      stuck: field(status_row, :stuck_reason) || if(waiting in [:backing_off, :unresponsive], do: waiting)
    }
  end

  defp runtime(status_row, member) do
    %{
      bucket: field(status_row, :bucket),
      work_state: field(status_row, :work_state),
      waiting_reason: field(status_row, :waiting_reason),
      tracker_paused?: field(status_row, :tracker_paused) == true,
      runtime_seconds: field(status_row, :runtime_seconds),
      stale_for_seconds: field(status_row, :stale_for_seconds),
      membership_lifecycle: Map.get(member, :lifecycle)
    }
  end

  defp decision_count(decision_row, status_row) do
    value =
      field(decision_row, :open_command_count) ||
        field(decision_row, :open_count) ||
        field(decision_row, :count) ||
        field(status_row, :open_decision_count)

    if is_integer(value) and value >= 0, do: value
  end

  defp command_count_source(decision_row, _status_row) when not is_nil(decision_row), do: :decisions
  defp command_count_source(_decision_row, status_row) when not is_nil(status_row), do: :status_report
  defp command_count_source(_decision_row, _status_row), do: :unknown

  defp activity_value(activity_row, key) do
    value = field(activity_row, key)
    if is_map(value), do: value, else: %{status: :unknown}
  end

  defp source_descriptor(source, entry) do
    %{
      available?: not is_nil(entry),
      health: health(source),
      freshness: field(source, :freshness) || field(source, :status) || :unknown,
      generation: field(source, :generation)
    }
  end

  defp source_generations(membership, status, activity, decisions, facts) do
    %{
      membership: field(membership, :generation),
      status: field(status, :generation),
      activity: field(activity, :generation),
      decisions: field(decisions, :generation),
      issue: field(facts, :generation)
    }
  end

  defp source_health(membership, status, activity, decisions, facts) do
    %{membership: health(membership), status: health(status), activity: health(activity), decisions: health(decisions), issue: health(facts)}
  end

  defp source_freshness(membership, status, activity, decisions, facts) do
    %{
      membership: field(membership, :freshness) || :unknown,
      status: field(status, :freshness) || :unknown,
      activity: field(activity, :freshness) || :unknown,
      decisions: field(decisions, :freshness) || :unknown,
      issue: field(facts, :freshness) || :unknown
    }
  end

  defp health(source) do
    case field(source, :health) do
      {:degraded, _reason} -> :degraded
      {:unavailable, _reason} -> :unavailable
      %{status: status} -> status
      status when status in [:healthy, :available, :degraded, :unavailable, :unknown] -> status
      _status -> :unknown
    end
  end

  defp normalize_url(url, %TrackerIdentity{} = identity) when is_binary(url) do
    with %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: query, path: path} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- default_port?(scheme, port),
         true <- is_binary(host) and String.downcase(host) == "github.com" and query in [nil, ""],
         [owner, repository, "issues", identifier] <- String.split(path || "", "/", trim: true),
         true <- same?(owner, identity.owner),
         true <- same?(repository, identity.repository),
         true <- identifier == identity.identifier do
      uri |> Map.put(:fragment, nil) |> URI.to_string()
    else
      _value -> nil
    end
  end

  defp normalize_url(_url, _identity), do: nil

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, _port), do: false

  defp same?(left, right) when is_binary(left) and is_binary(right), do: String.downcase(left) == String.downcase(right)
  defp same?(_left, _right), do: false

  defp field(value, key, default \\ nil)
  defp field(%{} = value, key, default), do: Map.get(value, key, Map.get(value, Atom.to_string(key), default))
  defp field(_value, _key, default), do: default
  defp present?(value), do: not is_nil(value) and value != ""
end
