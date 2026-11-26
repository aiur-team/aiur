defmodule Aiur.OverlapReviewer.Matcher do
  @moduledoc "Compares planned work using titles and explicit references in tracker descriptions."

  alias Aiur.SecretRedactor

  @title_noise ~w(a an the of on to for from and or by with in add fix update implement make change support)
  @file_pattern ~r"(?<![\w/:.-])(?:[\w.-]+/)+[\w.-]+\.[a-zA-Z][a-zA-Z0-9]{0,9}\b"
  @symbol_pattern ~r"(?<![\w./])(?:[A-Z]\w*\.)+[a-z_]\w*[!?]?(?:/\d+)?|(?<![\w./])[a-z_]\w*[!?]?/\d+\b"
  @empty_evidence %{title_terms: [], files: [], symbols: []}

  @type kind :: :issue | :open_pr | :merged_pr
  @type document :: %{
          kind: kind(),
          number: pos_integer(),
          ticket_numbers: [pos_integer()],
          title_terms: MapSet.t(String.t()),
          files: MapSet.t(String.t()),
          symbols: MapSet.t(String.t())
        }
  @type evidence :: %{title_terms: [String.t()], files: [String.t()], symbols: [String.t()]}
  @type verdict :: %{action: :build | :extend | :fold, target: document() | nil, evidence: evidence()}
  @type overlap :: %{left: document(), right: document(), features: [String.t()], scope: :within | :across, evidence: evidence()}

  @spec document(kind(), pos_integer(), String.t() | nil, String.t() | nil, [pos_integer()]) :: document()
  def document(kind, number, title, body, ticket_numbers \\ []) do
    title = bounded_text(title, 500)
    body = bounded_text(body, 16_000)
    text = title <> "\n" <> body

    %{
      kind: kind,
      number: number,
      ticket_numbers: if(kind == :issue, do: [number], else: Enum.uniq(ticket_numbers)),
      title_terms: title_terms(title),
      files: references(@file_pattern, text),
      symbols: references(@symbol_pattern, text)
    }
  end

  @spec review(document(), [document()]) :: verdict()
  def review(subject, corpus) do
    corpus
    |> Stream.flat_map(&matches(subject, &1))
    |> Enum.max_by(&rank/1, fn -> nil end)
    |> case do
      nil -> %{action: :build, target: nil, evidence: @empty_evidence}
      {target, evidence, _strength} -> %{action: if(target.kind == :open_pr, do: :extend, else: :fold), target: target, evidence: evidence}
    end
  end

  @spec feature_scan([document()], %{optional(pos_integer()) => [String.t()]}) :: [overlap()]
  def feature_scan(documents, memberships) do
    members =
      for document <- documents,
          document.kind != :merged_pr,
          features = features(document, memberships),
          features != [],
          do: {document.number, {document, features}}

    by_number = Map.new(members)
    index = Enum.reduce(members, %{}, &index_member/2)

    members
    |> Enum.flat_map(&feature_matches(&1, index, by_number))
    |> Enum.sort_by(&{&1.left.number, &1.right.number})
  end

  defp features(document, memberships) do
    Map.get(document, :feature_ticket_numbers, document.ticket_numbers)
    |> Enum.flat_map(&Map.get(memberships, &1, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp index_member({number, {document, _features}}, index) do
    Enum.reduce(keys(document), index, fn term, acc ->
      Map.update(acc, term, [number], &[number | &1])
    end)
  end

  defp feature_matches({number, {document, features}}, index, by_number) do
    # A match needs a shared title term or symbol. Compare those neighbors rather than scanning the entire backlog for each ticket.
    neighbors = document |> keys() |> Enum.flat_map(&Map.get(index, &1, [])) |> MapSet.new()

    for other_number <- neighbors,
        other_number > number,
        {other, other_features} = Map.fetch!(by_number, other_number),
        {target, evidence, _strength} <- matches(document, other) do
      all_features = Enum.sort(Enum.uniq(features ++ other_features))
      scope = if length(all_features) == 1, do: :within, else: :across
      %{left: document, right: target, features: all_features, scope: scope, evidence: evidence}
    end
  end

  defp keys(document), do: MapSet.union(document.title_terms, document.symbols)

  defp matches(left, right) do
    with false <- same_work_item?(left, right),
         {title_overlap, ratio} = title_match(left, right),
         evidence = %{title_terms: title_overlap, files: shared(left.files, right.files), symbols: shared(left.symbols, right.symbols)},
         strength when strength > 0 <- strength(evidence, ratio) do
      [{right, evidence, strength}]
    else
      _ -> []
    end
  end

  defp same_work_item?(left, right) do
    left.number == right.number or Enum.any?(left.ticket_numbers, &(&1 in right.ticket_numbers))
  end

  defp title_match(left, right) do
    title_overlap = shared(left.title_terms, right.title_terms)
    total = MapSet.size(left.title_terms) + MapSet.size(right.title_terms)
    {title_overlap, if(total == 0, do: 0, else: 2 * length(title_overlap) / total)}
  end

  defp strength(%{title_terms: [_, _ | _]}, 1.0), do: 4
  defp strength(%{title_terms: [_, _, _ | _]}, ratio) when ratio >= 0.8, do: 3
  defp strength(%{files: [_ | _], symbols: [_ | _]}, _ratio), do: 2
  defp strength(%{title_terms: [_, _ | _], symbols: [_ | _]}, ratio) when ratio >= 0.50, do: 2
  defp strength(%{title_terms: [_, _ | _], files: [_, _ | _]}, ratio) when ratio >= 0.50, do: 1
  defp strength(_evidence, _ratio), do: 0

  defp rank({target, evidence, strength}) do
    # Prefer live code for equivalent matches and break ties in stable number order.
    kind = %{open_pr: 2, merged_pr: 1, issue: 0}
    {strength, kind[target.kind], length(evidence.files) + length(evidence.symbols), -target.number}
  end

  defp title_terms(title) do
    title
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(byte_size(&1) < 3 or byte_size(&1) > 60 or &1 in @title_noise or Regex.match?(~r/^\d+$/, &1)))
    |> MapSet.new()
  end

  defp references(pattern, text) do
    pattern
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
    |> Enum.filter(&(byte_size(&1) <= 160))
    |> MapSet.new()
  end

  defp bounded_text(value, max) when is_binary(value), do: value |> String.slice(0, max) |> SecretRedactor.redact()
  defp bounded_text(_value, _max), do: ""

  defp shared(left, right), do: left |> MapSet.intersection(right) |> Enum.sort()
end
