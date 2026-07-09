defmodule Aiur.AgentList.Renderer.EventLine do
  @moduledoc """
  Event-ticker line formatting for the agent-list renderer.
  """

  alias Aiur.AgentList.Renderer.{EventPhrases, Links}

  @spec format_event_line(map(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def format_event_line(%{kind: kind, topic: topic} = entry, rendering_identifier, repo) do
    if ticker_self_echo?(kind, topic, entry) do
      nil
    else
      glyph = event_glyph(kind)
      body = Map.get(entry, :body)
      source_id = event_source_ticket_id(topic)
      subject_id = event_subject_id(kind, entry, source_id, rendering_identifier)
      suffix = topic_suffix(topic)

      {verb_phrase, summary} = describe_event(kind, subject_id, source_id, suffix, body)

      # OSC 8 wraps. Subject id linkable to its issue; "PR" / "comment"
      # tokens in the verb phrase get wrapped with the body's URL when
      # available, falling back to the subject's issue URL.
      linked_subject = Links.link_ticket_id(subject_id, repo)
      fallback_url = Links.issue_url_for(subject_id, repo) || Links.issue_url_for(source_id, repo)
      linked_verb = Links.link_verb_phrase(verb_phrase, kind, suffix, body, repo, fallback_url)

      "#{glyph} #{linked_subject} #{linked_verb}#{summary}"
    end
  end

  def format_event_line(_entry, _rendering_identifier, _repo), do: nil

  @spec event_glyph(atom()) :: String.t()
  def event_glyph(:publish), do: "💬"
  def event_glyph(:receive), do: "📬"
  def event_glyph(:read), do: "📄"
  def event_glyph(_), do: "·"

  @spec event_source_ticket_id(term()) :: String.t() | nil
  def event_source_ticket_id(topic) when is_binary(topic) do
    case Regex.run(~r/^ticket\.([^.]+)\./, topic) do
      [_, id] -> id
      _ -> nil
    end
  end

  def event_source_ticket_id(_), do: nil

  @spec ticker_self_echo?(atom(), term(), map()) :: boolean()
  def ticker_self_echo?(:receive, topic, %{identifier: id})
      when is_binary(topic) and is_binary(id) do
    source = event_source_ticket_id(topic)
    suffix = topic_suffix(topic)

    source == id and not comment_topic?(suffix)
  end

  def ticker_self_echo?(_kind, _topic, _entry), do: false

  @spec comment_topic?(String.t()) :: boolean()
  def comment_topic?("issue.commented"), do: true
  def comment_topic?("pr.review_comment"), do: true
  def comment_topic?(_), do: false

  @spec event_subject_id(atom(), map(), String.t() | nil, String.t() | nil) :: String.t()
  def event_subject_id(:publish, _entry, source_id, _rendering_identifier)
      when is_binary(source_id),
      do: source_id

  def event_subject_id(:receive, %{identifier: id}, _source_id, _rendering_identifier)
      when is_binary(id),
      do: id

  def event_subject_id(:read, %{identifier: id}, _source_id, _rendering_identifier)
      when is_binary(id),
      do: id

  def event_subject_id(:read, _entry, source_id, _rendering_identifier)
      when is_binary(source_id),
      do: source_id

  def event_subject_id(_kind, _entry, _source_id, rendering_identifier)
      when is_binary(rendering_identifier),
      do: rendering_identifier

  def event_subject_id(_kind, _entry, _source_id, _rendering_identifier), do: "?"

  @spec topic_suffix(term()) :: String.t()
  def topic_suffix("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_id, suffix] -> suffix
      _ -> rest
    end
  end

  def topic_suffix(topic) when is_binary(topic), do: topic
  def topic_suffix(_), do: ""

  @spec describe_event(atom(), String.t(), String.t() | nil, String.t(), term()) :: {String.t(), String.t()}
  def describe_event(:receive, subject_id, source_id, "issue.commented", body)
      when subject_id == source_id do
    {"new Issue comment:", EventPhrases.comment_body_summary(body)}
  end

  def describe_event(:receive, subject_id, source_id, "pr.review_comment", body)
      when subject_id == source_id do
    {"new PR comment:", EventPhrases.comment_body_summary(body)}
  end

  # --- Cross-ticket receive: "<receiver> ← <source>: <verb>" ------------
  def describe_event(:receive, _subject_id, source_id, suffix, body) when is_binary(source_id) do
    {"← #{source_id}: #{cross_receive_verb(suffix)}", cross_receive_summary(suffix, body)}
  end

  def describe_event(:receive, _subject_id, _source_id, _suffix, _body) do
    {"received", ""}
  end

  # --- Read events (digest ingestion) ----------------------------------
  # A read entry is the receiver digesting an event from its inbox.
  # The line reads `📄 <receiver> ingested <source>: <publish-verb>"<body>"`
  # so the operator can see what the agent actually picked up. We
  # reuse `publish_event_phrase/2` for the verb + body so reads share
  # the same vocabulary as the originating publish line.
  def describe_event(:read, subject_id, source_id, suffix, body)
      when is_binary(source_id) and source_id != subject_id do
    {verb, summary} = EventPhrases.publish_event_phrase(suffix, body)
    {"ingested #{source_id}: #{verb}", summary}
  end

  def describe_event(:read, _subject_id, _source_id, suffix, body) do
    {verb, summary} = EventPhrases.publish_event_phrase(suffix, body)
    {"ingested: #{verb}", summary}
  end

  # --- Publishes -------------------------------------------------------
  def describe_event(:publish, _subject_id, _source_id, suffix, body) do
    EventPhrases.publish_event_phrase(suffix, body)
  end

  def describe_event(_kind, _subject_id, _source_id, _suffix, _body), do: {"", ""}

  @spec cross_receive_verb(String.t()) :: String.t()
  def cross_receive_verb("branch.push"), do: "pushed"
  def cross_receive_verb("pr.opened"), do: "opened a PR"
  def cross_receive_verb("pr.merged"), do: "merged a PR"
  def cross_receive_verb("pr.review_comment"), do: "PR review comment"
  def cross_receive_verb("issue.commented"), do: "commented"
  def cross_receive_verb("agent.unblocked"), do: "unblocked"
  def cross_receive_verb("agent.blocked"), do: "blocked"
  def cross_receive_verb("agent.phase." <> phase_step), do: EventPhrases.phrase_for_phase(phase_step)
  def cross_receive_verb("agent.progress"), do: "progress"
  def cross_receive_verb("agent." <> name), do: name
  def cross_receive_verb(other), do: other

  @spec cross_receive_summary(String.t(), term()) :: String.t()
  def cross_receive_summary("branch.push", body) do
    case EventPhrases.branch_push_phrase(body) do
      {_verb, ""} -> ""
      {_verb, summary} -> summary
    end
  end

  def cross_receive_summary(suffix, body) when suffix in ["pr.opened", "pr.merged"] do
    case EventPhrases.pr_title(body) do
      nil -> ""
      title -> " \"" <> EventPhrases.clip_summary(title) <> "\""
    end
  end

  def cross_receive_summary(suffix, body)
      when suffix in ["issue.commented", "pr.review_comment"] do
    EventPhrases.comment_body_summary(body)
  end

  def cross_receive_summary(_suffix, body), do: EventPhrases.inline_summary(body)
end
