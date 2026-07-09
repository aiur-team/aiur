defmodule Aiur.AgentList.Renderer.Links do
  @moduledoc """
  OSC 8 hyperlink helpers for the agent-list renderer.
  """

  alias Aiur.AgentList.Renderer.EventPhrases

  @spec ticket_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  @spec issue_url_for(String.t() | nil, String.t() | nil) :: String.t() | nil
  @spec repo_identity(map()) :: String.t() | nil
  @spec osc8(String.t(), String.t()) :: String.t()
  @spec link_ticket_id(String.t(), String.t() | nil) :: String.t()
  @spec issue_url(String.t(), String.t()) :: String.t()
  @spec pr_url(String.t(), String.t() | integer()) :: String.t()
  @spec link_verb_phrase(String.t(), atom(), String.t(), term(), String.t() | nil, String.t() | nil) :: String.t()
  @spec pr_linkable?(String.t()) :: boolean()
  @spec pr_link_target(term(), String.t(), String.t() | nil) :: String.t() | nil
  @spec pr_html_url(term()) :: String.t() | nil
  @spec pr_number_url(term(), String.t()) :: String.t() | nil
  @spec comment_link_target(term(), String.t(), String.t() | nil) :: String.t() | nil
  @spec wrap_token(String.t(), String.t(), String.t() | nil) :: String.t()

  def ticket_url(project, id_str) when is_binary(project) and is_binary(id_str) do
    case Integer.parse(id_str) do
      {n, ""} when n > 0 -> "https://github.com/" <> project <> "/issues/" <> Integer.to_string(n)
      _ -> nil
    end
  end

  def ticket_url(_project, _id_str), do: nil

  def issue_url_for(id, repo) when is_binary(id) and is_binary(repo), do: issue_url(repo, id)
  def issue_url_for(_id, _repo), do: nil

  def repo_identity(state) do
    case Map.get(state, :repo_identity) || Map.get(state, :project_label) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  def osc8(url, text) when is_binary(url) and is_binary(text) do
    "\e]8;;" <> url <> "\e\\" <> text <> "\e]8;;\e\\"
  end

  def link_ticket_id(id, repo) when is_binary(id) and is_binary(repo) do
    osc8(issue_url(repo, id), id)
  end

  def link_ticket_id(id, _repo) when is_binary(id), do: id

  def issue_url(repo, id), do: "https://github.com/#{repo}/issues/#{id}"

  def pr_url(repo, number), do: "https://github.com/#{repo}/pull/#{number}"

  def link_verb_phrase(verb_phrase, _kind, suffix, body, repo, fallback_url)
      when is_binary(verb_phrase) do
    cond do
      repo == nil ->
        verb_phrase

      String.contains?(verb_phrase, "PR") and pr_linkable?(suffix) ->
        wrap_token(verb_phrase, "PR", pr_link_target(body, repo, fallback_url))

      String.contains?(verb_phrase, "comment") ->
        wrap_token(verb_phrase, "comment", comment_link_target(body, suffix, fallback_url))

      true ->
        verb_phrase
    end
  end

  def pr_linkable?("pr.opened"), do: true
  def pr_linkable?("pr.merged"), do: true
  def pr_linkable?("pr.review_comment"), do: true
  def pr_linkable?(_), do: false

  def pr_link_target(body, repo, fallback) when is_map(body) do
    pr_html_url(body) || pr_number_url(body, repo) || fallback
  end

  def pr_link_target(_body, _repo, fallback), do: fallback

  def pr_html_url(body) do
    candidate = EventPhrases.get_in_safe(body, [:pr, "html_url"]) || EventPhrases.get_in_safe(body, ["pr", "html_url"])
    if is_binary(candidate) and candidate != "", do: candidate
  end

  def pr_number_url(body, repo) do
    case EventPhrases.get_in_safe(body, [:pr, "number"]) || EventPhrases.get_in_safe(body, ["pr", "number"]) do
      n when is_integer(n) -> pr_url(repo, n)
      n when is_binary(n) and n != "" -> pr_url(repo, n)
      _ -> nil
    end
  end

  def comment_link_target(body, suffix, fallback) when is_map(body) do
    candidate =
      EventPhrases.get_in_safe(body, [:comment, "html_url"]) || EventPhrases.get_in_safe(body, ["comment", "html_url"])

    cond do
      is_binary(candidate) and candidate != "" -> candidate
      suffix == "pr.review_comment" -> pr_html_url(body) || fallback
      true -> fallback
    end
  end

  def comment_link_target(_body, _suffix, fallback), do: fallback

  def wrap_token(text, _token, target) when target in [nil, ""], do: text

  def wrap_token(text, token, target) when is_binary(target) do
    case :binary.match(text, token) do
      :nomatch ->
        text

      {start, length} ->
        {prefix, rest} = String.split_at(text, start)
        {match, suffix} = String.split_at(rest, length)
        prefix <> osc8(target, match) <> suffix
    end
  end
end
