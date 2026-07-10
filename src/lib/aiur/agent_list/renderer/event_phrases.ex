defmodule Aiur.AgentList.Renderer.EventPhrases do
  @moduledoc "Event vocabulary and payload summarization helpers for the agent-list renderer."

  @spec publish_event_phrase(String.t(), term()) :: {String.t(), String.t()}
  def publish_event_phrase("agent.phase." <> phase_step, body),
    do: {phrase_for_phase(phase_step) <> ":", inline_summary(body)}

  def publish_event_phrase("agent.progress.checkin", body), do: progress_phrase("Check-in:", body)

  def publish_event_phrase("agent.progress.phase", body),
    do: progress_phrase("Estimated progress:", body)

  def publish_event_phrase("agent.progress", body), do: progress_phrase("Estimated progress:", body)

  def publish_event_phrase("agent.blocked", body), do: {"blocked:", inline_summary(body)}

  def publish_event_phrase("agent.unblocked", body), do: {"unblocked", inline_summary(body)}

  def publish_event_phrase("agent.pause.request", body), do: {"requested pause", inline_summary(body)}

  def publish_event_phrase("agent.attention." <> _slug, body),
    do: {"raised attention:", inline_summary(body)}

  def publish_event_phrase("agent.decision." <> slug, body),
    do: {"decided #{slug}:", inline_summary(body)}

  def publish_event_phrase("agent." <> name, body), do: {name <> ":", inline_summary(body)}

  def publish_event_phrase("operator.progress_request", _body), do: {"check-in requested", ""}

  def publish_event_phrase("issue.label.added.agent." <> state, body),
    do: {"labelled #{state}:", inline_summary(body)}

  def publish_event_phrase("pr.opened", body), do: pr_event_phrase("opened a PR", body)

  def publish_event_phrase("pr.merged", body), do: pr_event_phrase("merged a PR", body)

  def publish_event_phrase("pr.review_comment", body),
    do: {"got a PR review comment:", comment_body_summary(body)}

  def publish_event_phrase("ci.passed", _body), do: {"CI passed", ""}

  def publish_event_phrase("ci.failed", body), do: {"CI failed:", inline_summary(body)}

  def publish_event_phrase("branch.push", body), do: branch_push_phrase(body)

  def publish_event_phrase("issue.commented", body),
    do: {"got an issue comment:", comment_body_summary(body)}

  def publish_event_phrase(other, body), do: {other, inline_summary(body)}

  @spec progress_phrase(String.t(), term()) :: {String.t(), String.t()}
  def progress_phrase(verb, body) do
    case progress_percent_from(body) do
      nil ->
        {verb, inline_summary(body)}

      pct ->
        suffix =
          case progress_label_from(body) do
            nil -> ""
            label -> " \"" <> clip_summary(label) <> "\""
          end

        {"#{verb} #{trunc(pct)}% done", suffix}
    end
  end

  @spec progress_percent_from(term()) :: number() | nil
  def progress_percent_from(body) when is_map(body) do
    cond do
      is_number(body[:percent]) -> body[:percent]
      is_number(body["percent"]) -> body["percent"]
      true -> nil
    end
  end

  def progress_percent_from(_), do: nil

  @spec progress_label_from(term()) :: String.t() | nil
  def progress_label_from(body) when is_map(body) do
    candidate = body[:label] || body["label"]
    if is_binary(candidate) and String.trim(candidate) != "", do: candidate
  end

  def progress_label_from(_), do: nil

  @spec pr_event_phrase(String.t(), term()) :: {String.t(), String.t()}
  def pr_event_phrase(verb, body) do
    case pr_title(body) do
      nil -> {verb, ""}
      title -> {verb <> ":", " \"" <> clip_summary(title) <> "\""}
    end
  end

  @spec branch_push_phrase(term()) :: {String.t(), String.t()}
  def branch_push_phrase(body) do
    commits = get_in_safe(body, [:commits]) || get_in_safe(body, ["commits"]) || []

    if is_list(commits) and commits != [] do
      count = length(commits)
      last = commits |> List.last() |> commit_message()

      case last do
        nil ->
          {"pushed #{count} #{commits_word(count)}", ""}

        msg ->
          {"pushed #{count} #{commits_word(count)}, last:", " \"" <> clip_summary(msg) <> "\""}
      end
    else
      {"pushed", ""}
    end
  end

  @spec commits_word(integer()) :: String.t()
  def commits_word(1), do: "commit"
  def commits_word(_), do: "commits"

  @spec commit_message(term()) :: String.t() | nil
  def commit_message(%{} = commit) do
    Map.get(commit, "message") || Map.get(commit, :message)
  end

  def commit_message(_), do: nil

  @spec phrase_for_phase(String.t()) :: String.t()
  def phrase_for_phase("brainstorm.start"), do: "started brainstorm"
  def phrase_for_phase("brainstorm.end"), do: "finished brainstorm"
  def phrase_for_phase("plan.start"), do: "started plan"
  def phrase_for_phase("plan.end"), do: "finished plan"
  def phrase_for_phase("work.start"), do: "started work"
  def phrase_for_phase("work.end"), do: "finished work"
  def phrase_for_phase("review.start"), do: "started review"
  def phrase_for_phase("review.end"), do: "finished review"
  def phrase_for_phase(other), do: "phase " <> other

  @summary_keys ~w(message title summary subject name label commit_message)

  @spec inline_summary(term()) :: String.t()
  def inline_summary(body) when is_map(body) do
    case extract_event_text(body, @summary_keys) do
      nil -> ""
      text -> " \"" <> clip_summary(text) <> "\""
    end
  end

  def inline_summary(_body), do: ""

  @spec comment_body_summary(term()) :: String.t()
  def comment_body_summary(body) when is_map(body) do
    nested = get_in_safe(body, [:comment, "body"]) || get_in_safe(body, ["comment", "body"])

    if is_binary(nested) and String.trim(nested) != "" do
      " \"" <> clip_summary(String.trim(nested)) <> "\""
    else
      inline_summary(body)
    end
  end

  def comment_body_summary(_body), do: ""

  @spec pr_title(term()) :: String.t() | nil
  def pr_title(body) when is_map(body) do
    candidate = get_in_safe(body, [:pr, "title"]) || get_in_safe(body, ["pr", "title"])

    if is_binary(candidate) and String.trim(candidate) != "" do
      String.trim(candidate)
    end
  end

  def pr_title(_body), do: nil

  @spec extract_event_text(map(), [String.t()]) :: String.t() | nil
  def extract_event_text(body, keys) do
    Enum.find_value(keys, fn k ->
      val = Map.get(body, k) || Map.get(body, String.to_atom(k))

      if is_binary(val) and String.trim(val) != "" do
        String.trim(val)
      end
    end)
  end

  @spec clip_summary(String.t()) :: String.t()
  def clip_summary(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @spec get_in_safe(term(), [term()]) :: term() | nil
  def get_in_safe(nil, _path), do: nil
  def get_in_safe(body, []), do: body

  def get_in_safe(body, [key | rest]) when is_map(body) do
    case Map.get(body, key) do
      nil -> nil
      child -> get_in_safe(child, rest)
    end
  end

  def get_in_safe(_body, _path), do: nil
end
