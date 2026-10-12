defmodule Aiur.RecentMerge.ClosingReferences do
  @moduledoc """
  Parses GitHub closing keywords (`Closes #123`) out of a pull request body.

  Narrower than GitHub on purpose — see `Aiur.RecentMerge.closing_issue_identifiers/1`
  for the recognised and ignored forms.
  """

  @spec identifiers_in_body(String.t() | nil, String.t() | nil) :: [String.t()]
  def identifiers_in_body(body, repository) do
    body
    |> references()
    |> Enum.filter(fn {reference_repository, _number} ->
      reference_repository == nil or same_repository?(reference_repository, repository)
    end)
    |> Enum.map(fn {_repository, number} -> number end)
    |> Enum.uniq()
  end

  @spec preserve(String.t() | nil, [{String.t() | nil, String.t()}], pos_integer()) :: String.t() | nil
  def preserve(summary, [], _max), do: summary

  def preserve(summary, references, max) when is_binary(summary) do
    missing = Enum.reject(references, &(&1 in references(summary)))

    if missing == [] do
      summary
    else
      suffix = closing_reference_suffix(missing, max)
      String.slice(summary, 0, max - String.length(suffix)) <> suffix
    end
  end

  def preserve(summary, _references, _max), do: summary

  # Each retained reference gets its own keyword on its own line: a
  # comma-chained list would silently lose every reference after the first
  # when the summary is read back.
  defp closing_reference_suffix(references, max) do
    Enum.reduce(references, "", fn reference, suffix ->
      candidate = suffix <> "\nCloses " <> reference_text(reference)

      if String.length(candidate) <= max, do: candidate, else: suffix
    end)
  end

  defp reference_text({nil, number}), do: "##{number}"
  defp reference_text({repository, number}), do: "#{repository}##{number}"

  # A keyword counts only where it opens a line, a list item, or a clause
  # introduced by `,`, `;` or `and`, and it must be followed by its own
  # reference. See `closing_issue_identifiers/1` for why this is narrower than
  # GitHub in prose position.
  @closing_reference_regex ~r/
    (?:^[ \t]*(?:[-*+][ \t]+|\d+[.)][ \t]+)?|[,;][ \t]*|\band[ \t]+)
    \**
    (?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)
    \**
    (?::[ \t]*|[ \t]+)
    (?<repository>[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?
    \#(?<number>\d+)\b
  /imx

  @spec references(term()) :: [{String.t() | nil, String.t()}]
  def references(text) when is_binary(text) do
    text
    |> quotable_text()
    |> then(&Regex.scan(@closing_reference_regex, &1, capture: [:repository, :number]))
    |> Enum.map(fn [repository, number] -> {empty_to_nil(repository), number} end)
    |> Enum.filter(fn {_repository, number} -> String.to_integer(number) > 0 end)
    |> Enum.map(fn {repository, number} ->
      {repository, number |> String.to_integer() |> Integer.to_string()}
    end)
    |> Enum.uniq()
  end

  def references(_text), do: []

  # Drops the regions GitHub itself does not read closing keywords from:
  # fenced code blocks, inline code spans and blockquotes.
  defp quotable_text(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({[], nil}, &collect_quotable_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp collect_quotable_line(line, {kept, nil}) do
    case fence_marker(line) do
      nil -> {maybe_keep_line(line, kept), nil}
      marker -> {kept, marker}
    end
  end

  defp collect_quotable_line(line, {kept, open_marker}) do
    case fence_marker(line) do
      marker when is_binary(marker) and byte_size(marker) >= byte_size(open_marker) ->
        if String.first(marker) == String.first(open_marker), do: {kept, nil}, else: {kept, open_marker}

      _ ->
        {kept, open_marker}
    end
  end

  defp maybe_keep_line(line, kept) do
    if blockquote_line?(line), do: kept, else: [strip_inline_code(line) | kept]
  end

  defp fence_marker(line) do
    case Regex.run(~r/^[ \t]{0,3}(`{3,}|~{3,})/, line) do
      [_match, marker] -> marker
      nil -> nil
    end
  end

  defp blockquote_line?(line), do: Regex.match?(~r/^[ \t]{0,3}>/, line)

  defp strip_inline_code(line), do: String.replace(line, ~r/`[^`]*`/, " ")

  defp same_repository?(reference_repository, repository) when is_binary(repository) do
    String.downcase(reference_repository) == String.downcase(repository)
  end

  defp same_repository?(_reference_repository, _repository), do: false

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
