defmodule Aiur.IssueContext do
  @moduledoc """
  Builds a compact, human-readable summary of an issue for the
  conversation pane's "intro" system message. The pane renders this once
  at open time so the operator knows what the agent is working on
  without having to switch to GitHub/Linear.

  Source of truth for issue details varies by tracker. We probe the
  cheapest sources first (the orchestrator's running-issue map; the
  tracker's candidate cache) and only hit the live tracker if nothing
  is locally available.
  """

  alias Aiur.{Issue, Tracker}

  @type summary :: %{
          identifier: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()]
        }

  @doc """
  Returns a context summary for `identifier`. Always returns a map, even
  when no detail is available — callers can render the placeholder.
  """
  @spec for(String.t()) :: summary()
  def for(identifier) when is_binary(identifier) do
    case lookup_issue(identifier) do
      %Issue{} = issue -> from_issue(issue)
      nil -> empty(identifier)
    end
  end

  @doc """
  Renders a multi-line system message body from a summary. Used by the
  conversation pane to prepend an intro line to the transcript.
  """
  @spec to_message(summary()) :: String.t()
  def to_message(%{identifier: identifier} = summary) do
    [
      "Working on #{identifier}" <> title_suffix(summary[:title]),
      url_line(summary[:url]),
      labels_line(summary[:labels]),
      blockers_line(summary[:blocked_by]),
      description_block(summary[:description])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---------- internals -----------------------------------------------------

  defp lookup_issue(identifier) do
    case safe_call(fn -> Tracker.fetch_candidate_issues() end) do
      {:ok, issues} when is_list(issues) ->
        Enum.find(issues, fn
          %Issue{identifier: ^identifier} -> true
          _ -> false
        end)

      _ ->
        nil
    end
  end

  defp from_issue(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      url: issue.url,
      labels: List.wrap(issue.labels),
      blocked_by: List.wrap(issue.blocked_by)
    }
  end

  defp empty(identifier) do
    %{identifier: identifier, title: nil, description: nil, url: nil, labels: [], blocked_by: []}
  end

  defp title_suffix(nil), do: ""
  defp title_suffix(""), do: ""
  defp title_suffix(title), do: ": #{title}"

  defp url_line(nil), do: nil
  defp url_line(""), do: nil
  defp url_line(url), do: "  #{url}"

  defp labels_line([]), do: nil

  defp labels_line(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      names -> "  labels: " <> Enum.join(names, ", ")
    end
  end

  defp blockers_line([]), do: nil

  defp blockers_line(blockers) do
    blockers
    |> Enum.map(&blocker_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      labels -> "  blocked by: " <> Enum.join(labels, ", ")
    end
  end

  defp blocker_label(%{identifier: id, url: url}) when is_binary(id) and is_binary(url) do
    "#{id} (#{url})"
  end

  defp blocker_label(%{identifier: id}) when is_binary(id), do: id
  defp blocker_label(%{url: url}) when is_binary(url), do: url
  defp blocker_label(_), do: nil

  defp description_block(nil), do: nil
  defp description_block(""), do: nil

  defp description_block(text) do
    # Some trackers return descriptions where newlines have been escaped
    # to literal `\\n` strings (a single backslash followed by `n`). The
    # pane has no way to know those are line breaks unless we unescape
    # back to real newline bytes, so we always normalise here before
    # truncating + previewing.
    preview =
      text
      |> String.replace("\\n", "\n")
      |> String.split(~r/\r?\n/)
      |> Enum.take(12)
      |> Enum.join("\n")
      |> String.slice(0, 600)

    "\n" <> preview
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
