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

  @spec preserve_references(String.t() | nil, String.t() | nil, String.t(), pos_integer()) :: String.t() | nil
  def preserve_references(summary, body, repository, max) when is_binary(summary) do
    missing = Enum.reject(referenced_identifiers_in_body(body, repository), &(&1 in referenced_identifiers_in_body(summary, repository)))

    Enum.reduce(missing, summary, fn number, current ->
      suffix = "\nRefs ##{number}"
      String.slice(current, 0, max - String.length(suffix)) <> suffix
    end)
  end

  def preserve_references(summary, _body, _repository, _max), do: summary

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

  # GitHub recognizes closing keywords anywhere in the body, including prose
  # and issue URLs. Keep the parser aligned with that behavior.
  @closing_reference_regex ~r/

    \b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)
    (?:[ \t]+|:[ \t]+)
    (?<reference>https?:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/issues\/\d+|[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\#\d+|\#\d+)\b
  /imx

  @spec references(term()) :: [{String.t() | nil, String.t()}]
  def references(text) when is_binary(text) do
    text
    |> quotable_text()
    |> then(&Regex.scan(@closing_reference_regex, &1, capture: [:reference]))
    |> Enum.map(fn [reference] -> parse_closing_reference(reference) end)
    |> Enum.filter(fn {_repository, number} -> String.to_integer(number) > 0 end)
    |> Enum.map(fn {repository, number} -> {repository, number |> String.to_integer() |> Integer.to_string()} end)
    |> Enum.uniq()
  end

  def references(_text), do: []

  defp leading_part_of_reference(text) do
    case Regex.run(~r{\A[ \t]*part[ \t]+of[ \t]+(?:([A-Za-z0-9._-]+/[A-Za-z0-9._-]+))?#([0-9]+)\b}i, text, capture: :all) do
      [_match, repository, number] -> [{empty_to_nil(repository), number}]
      nil -> []
    end
  end

  defp parse_closing_reference(reference) do
    case Regex.run(~r{^https?://github\.com/([^/]+/[^/]+)/issues/(\d+)$}, reference) do
      [_match, repository, number] -> {repository, number}
      nil -> parse_non_url_reference(reference)
    end
  end

  defp parse_non_url_reference(reference) do
    case Regex.run(~r{^([^#]+)\#(\d+)$}, reference) do
      [_match, repository, number] -> {repository, number}
      nil -> {nil, Regex.replace(~r/^\#/, reference, "")}
    end
  end

  @reference_regex ~r/(?:^[ \t]*(?:[-*+][ \t]+|\d+[.)][ \t]+)?|[,;][ \t]*|\band[ \t]+)(?:refs?|mentions?|related[ \t]+to)[ \t]+(?<repository>[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?\#(?<number>\d+)\b/im

  @spec referenced_identifiers_in_body(String.t() | nil, String.t() | nil) :: [String.t()]
  def referenced_identifiers_in_body(body, repository) when is_binary(body) do
    body
    |> quotable_text()
    |> then(&Regex.scan(@reference_regex, &1, capture: [:repository, :number]))
    |> Enum.map(fn [reference_repository, number] -> {empty_to_nil(reference_repository), number} end)
    |> then(&(&1 ++ leading_part_of_reference(body)))
    |> Enum.filter(fn {reference_repository, _number} -> reference_repository == nil or same_repository?(reference_repository, repository) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(String.to_integer(&1) > 0))
    |> Enum.uniq()
  end

  def referenced_identifiers_in_body(_, _), do: []

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
