defmodule AiurWeb.OperatorControlCenter.TicketSearch do
  @moduledoc """
  Ranked, typo-forgiving matching of an operator's query against open tickets.

  The Tickets panel lists the whole open backlog, so the operator arrives
  knowing roughly what they want and not where it sorted. A raw
  `String.contains?/2` fails that: it is case- and punctuation-sensitive, it
  cannot match "retry" in a title against "storm" in a body, and it returns an
  unordered pile rather than the ticket the operator meant.

  So both sides are tokenised. A query becomes terms; a ticket becomes an index
  of its ID, title words, and a bounded excerpt of its description. **Every term
  must match somewhere** — extra typing always narrows, which is what makes the
  list feel like it is converging rather than churning. Each term scores its
  best field/tier hit and the scores are summed, so a title hit outranks a body
  hit and a whole word outranks a partial.

  Forgiveness is deliberately bounded. Prefix and infix hits carry the operator
  mid-word (`orchestr` finds "Orchestrator"), and a term of five characters or
  more may match a word one edit away — one substitution, insertion, deletion,
  or transposition. Two edits, or any slip in a short term, does not match:
  unbounded fuzz makes every ticket a weak hit, and a filter that matches
  everything is the same as no filter.
  """

  # Below this length a single edit routinely turns one real word into another
  # ("wale"/"wake", "rest"/"test"), so fuzz there produces confident nonsense.
  @min_fuzzy_length 5

  # Every term costs a scan of every ticket's index, so a pasted paragraph must
  # not become a hundred of them. Eight is well past what an operator types and
  # far short of what makes the filter a way to stall their own dashboard.
  @max_terms 8

  # One edit can change a term's byte length by up to four (a one-byte ASCII
  # character replaced by a four-byte codepoint), so anything further apart than
  # that cannot be one edit. `byte_size/1` is constant time where the grapheme
  # comparison is not, and this rejects nearly every word before allocating.
  @max_edit_byte_delta 4

  # Per-term scores, best hit wins. The bands are separated widely enough that
  # a field never overtakes a better field by tier alone: any title hit beats
  # any body hit, and within a field a whole word beats a partial.
  @id_scores %{exact: 120, prefix: 80}
  @title_scores %{exact: 100, prefix: 70, infix: 55, fuzzy: 45}
  @body_scores %{exact: 40, prefix: 28, infix: 20, fuzzy: 12}

  @type index :: %{id: String.t(), title: [String.t()], body: [String.t()]}

  @doc """
  Splits a query into comparable terms.

  Returns `[]` for anything with no alphanumeric content, which is how callers
  distinguish "not searching" from "searching and matching nothing".
  """
  @spec terms(String.t() | nil) :: [String.t()]
  def terms(query) when is_binary(query) do
    query
    # macOS composes accents as combining marks, so an NFD "café" would split
    # into "cafe" plus a mark and never match the NFC form GitHub stores. Marks
    # are kept as word characters for the same reason.
    |> :unicode.characters_to_nfc_binary()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}\p{M}]+/u, trim: true)
    # A repeated term cannot narrow the result but costs a full index scan, and
    # a pasted paragraph would otherwise buy an unbounded number of them.
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  def terms(_query), do: []

  @doc "Builds the comparison index for one presented row."
  @spec index(map()) :: index()
  def index(row) when is_map(row) do
    %{
      id: row |> Map.get(:identifier) |> to_string() |> String.downcase(),
      title: words(Map.get(row, :title)),
      body: words(Map.get(row, :body_excerpt))
    }
  end

  @doc """
  Stores the row's index on the row itself.

  The presenter indexes once per projection; filtering then runs per keystroke
  against the stored index rather than re-tokenising every title and body on
  every character typed.
  """
  @spec put_index(map()) :: map()
  def put_index(row) when is_map(row), do: Map.put(row, :search, index(row))

  @doc """
  Returns the rows matching `query`, best match first.

  A query with no terms returns `rows` untouched and in order — clearing the
  input restores the unfiltered list without a provider read.
  """
  @spec filter([map()], String.t() | nil) :: [map()]
  def filter(rows, query) when is_list(rows) do
    case terms(query) do
      [] ->
        rows

      terms ->
        # Each term's length and graphemes are derived once for the whole pass
        # rather than once per indexed word: the words change, the query does
        # not, and re-measuring it per word was most of the cost of a keystroke.
        prepared = Enum.map(terms, &prepare/1)

        rows
        # The source position is the tiebreak, so equally-scored rows keep the
        # provider's newest-first order instead of reshuffling per keystroke.
        |> Enum.with_index()
        |> Enum.flat_map(fn {row, position} -> scored(row, prepared, position) end)
        |> Enum.sort()
        |> Enum.map(fn {_rank, _position, row} -> row end)
    end
  end

  def filter(_rows, _query), do: []

  @doc "Scores one row against already-tokenised terms; `:no_match` if any term misses."
  @spec score(map(), [String.t()]) :: {:ok, non_neg_integer()} | :no_match
  def score(row, terms) when is_map(row) and is_list(terms) do
    scores(row, Enum.map(terms, &prepare/1))
  end

  defp scores(row, prepared) do
    index = Map.get(row, :search) || index(row)

    Enum.reduce_while(prepared, {:ok, 0}, fn term, {:ok, total} ->
      case term_score(index, term) do
        0 -> {:halt, :no_match}
        points -> {:cont, {:ok, total + points}}
      end
    end)
  end

  defp prepare(term) do
    graphemes = String.graphemes(term)
    %{text: term, bytes: byte_size(term), length: length(graphemes), graphemes: graphemes}
  end

  defp scored(row, prepared, position) do
    case scores(row, prepared) do
      # Negated so a plain ascending sort puts the best match first.
      {:ok, points} -> [{-points, position, row}]
      :no_match -> []
    end
  end

  # The score bands are disjoint by field, so a better field's hit can never be
  # beaten by a worse field's. Stopping as soon as the best remaining field
  # cannot improve on what is already scored skips the body scan — the long
  # one — for every term that already matched an ID or a title.
  defp term_score(index, term) do
    id_points = id_score(index.id, term)

    if id_points == @id_scores.exact do
      id_points
    else
      points = max(id_points, field_score(index.title, term, @title_scores))

      if points > @body_scores.exact do
        points
      else
        max(points, field_score(index.body, term, @body_scores))
      end
    end
  end

  # An ID is a single opaque token, not prose: a term is either the number the
  # operator typed or a prefix of it. Fuzz here would match unrelated tickets.
  defp id_score(id, %{text: text}) do
    cond do
      id == "" -> 0
      id == text -> @id_scores.exact
      String.starts_with?(id, text) -> @id_scores.prefix
      true -> 0
    end
  end

  defp field_score(words, term, scores) do
    Enum.reduce_while(words, 0, fn word, best ->
      case tier(word, term) do
        nil -> {:cont, best}
        :exact -> {:halt, scores.exact}
        found -> {:cont, max(best, Map.fetch!(scores, found))}
      end
    end)
  end

  defp tier(word, %{text: text} = term) do
    cond do
      word == text -> :exact
      String.starts_with?(word, text) -> :prefix
      String.contains?(word, text) -> :infix
      fuzzy?(word, term) -> :fuzzy
      true -> nil
    end
  end

  defp fuzzy?(word, %{length: length, bytes: bytes} = term) do
    length >= @min_fuzzy_length and abs(byte_size(word) - bytes) <= @max_edit_byte_delta and
      within_one_edit?(word, term)
  end

  # Bounded Damerau-Levenshtein: true when one substitution, one transposition,
  # or one insertion/deletion turns `term` into `word`. Written as a single
  # linear scan rather than a distance matrix — the words are short, this runs
  # for every word of every ticket on every keystroke, and "at most one" is the
  # only answer the ranking needs.
  defp within_one_edit?(word, %{graphemes: right, length: right_length}) do
    left = String.graphemes(word)

    case length(left) - right_length do
      0 -> substituted_or_transposed?(left, right)
      1 -> one_dropped?(left, right)
      -1 -> one_dropped?(right, left)
      _other -> false
    end
  end

  defp substituted_or_transposed?([same | left], [same | right]), do: substituted_or_transposed?(left, right)
  defp substituted_or_transposed?([a | left], [b | right]), do: left == right or transposed?(a, left, b, right)
  defp substituted_or_transposed?([], []), do: false

  # The heads `a` and `b` already differ, so a transposition means each side's
  # next grapheme is the other's head and the remainders agree.
  defp transposed?(a, [b | left], b, [a | right]), do: left == right
  defp transposed?(_a, _left, _b, _right), do: false

  defp one_dropped?([same | longer], [same | shorter]), do: one_dropped?(longer, shorter)
  defp one_dropped?([_dropped | longer], shorter), do: longer == shorter

  defp words(nil), do: []

  defp words(text) when is_binary(text) do
    text
    |> terms()
    # Repeated words cost a scan each and cannot improve a best-of score.
    |> Enum.uniq()
  end

  defp words(_text), do: []
end
