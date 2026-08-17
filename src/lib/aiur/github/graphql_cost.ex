defmodule Aiur.GitHub.GraphQLCost do
  @moduledoc """
  Makes every GraphQL query report what it spent, and names the call site that spent it.

  GitHub bills GraphQL in *points*, and the response headers never say what the
  call just cost — they report only the balance left afterwards. The price is
  available in exactly one place: a `rateLimit { cost }` selection inside the
  query itself. Asking for it is free. It is a field on the same `Query` root
  the request already resolves, so it adds no request, no page, and no point.

  Only `Aiur.BuildOrder.GitHubGraph.Queries` asked. Every other query was
  therefore recorded by `Aiur.GitHub.Quota` at one point and marked
  `:assumed` — which is how a 26-point catalog read and a 1-point viewer lookup
  came to look identical in the ranking, and why "where does the budget go" had
  no answer. The daemon burned a fresh 5,000-point budget in about 20 minutes
  while making 192 REST calls; a request-count ranking cannot see that, and a
  points ranking built on assumed costs is worse, because it is confidently
  wrong.

  ## Why injection is central rather than per query

  The alternative was to paste the selection into all thirteen query strings.
  That works once and then decays: the fourteenth query is written without it,
  is recorded at one point, and quietly understates the very thing the ranking
  exists to expose. Injecting at the transport chokepoint means a query cannot
  be added without being priced.

  The transform is deliberately timid. It declines rather than guesses:

    * a document already mentioning `rateLimit` is left exactly as written, so
      the Build Order templates keep their own selection and re-instrumenting is
      a no-op;
    * `mutation`, `subscription` and `fragment` documents are left alone —
      `rateLimit` is a field on `Query`, so injecting it into a mutation would
      turn a working write into a validation error;
    * anything whose top-level selection set cannot be located is returned
      unchanged.

  A declined document costs accuracy in the ranking, which `:cost_source`
  already reports. A mangled document costs a working request, so every
  ambiguity resolves toward declining.

  ## Call sites, not consumers

  `Quota` already attributes by *consumer* — the ticket a call was made for.
  That answers "which ticket is expensive". It cannot answer "which code path is
  expensive", and the batch queries make the difference stark: `CommentPollBatch`
  packs 33 targets into one document, so its cost belongs to the poller, not to
  any one of the 33 tickets it happens to mention.

  So the caller is a second, independent dimension. It is declared at the call
  site via `caller:` rather than inferred, because inference is what produced the
  `unattributed` bucket that hides batch queries today. Where a call site has not
  declared one, `derive/1` falls back to the GraphQL operation name — which is
  why every query in this tree is named — and then to a REST route shape.
  """

  @selection "rateLimit { limit cost remaining resetAt }"

  @doc "The selection injected into an uninstrumented query."
  @spec selection() :: String.t()
  def selection, do: @selection

  @doc """
  Returns `query` with a top-level `rateLimit` selection, or unchanged.

  Idempotent. See the moduledoc for the cases it declines.
  """
  @spec instrument(term()) :: term()
  def instrument(query) when is_binary(query) do
    if String.contains?(query, "rateLimit") do
      query
    else
      inject(query)
    end
  end

  def instrument(query), do: query

  defp inject(query) do
    case scan(query) do
      {:ok, offset} ->
        {head, tail} = String.split_at(query, offset)
        head <> "\n  " <> @selection <> tail

      :decline ->
        query
    end
  end

  # Walks the document once, tracking the lexical states in which a `{` means
  # something other than "open a selection set": inside a string, inside a block
  # string, after a `#`, or inside the parentheses of a variable definition
  # whose default value is an input object.
  # Anything without a `Query` root has already been declined, so the only
  # question left here is where the operation's selection set opens.
  defp scan(query) do
    case query_root?(query) do
      true -> selection_offset(query)
      false -> :decline
    end
  end

  # A `Query` root means either the `query` keyword or the shorthand form. A
  # `mutation`, `subscription` or fragment-led document has no `rateLimit` field
  # to select, and anything unrecognised is declined rather than guessed at.
  defp query_root?(query) do
    case query |> strip_leading_trivia() |> String.downcase() do
      "query" <> rest -> boundary?(rest)
      "{" <> _rest -> true
      _other -> false
    end
  end

  defp boundary?(<<char::utf8, _rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r, ?(, ?{, ?@], do: true
  defp boundary?(_rest), do: false

  # Comments and whitespace can precede the operation keyword. Nothing else may:
  # a document starting with anything other than an operation is declined above.
  defp strip_leading_trivia(query) do
    trimmed = String.trim_leading(query)

    case trimmed do
      "#" <> _rest ->
        trimmed
        |> String.split("\n", parts: 2)
        |> case do
          [_comment, rest] -> strip_leading_trivia(rest)
          [_comment] -> ""
        end

      _other ->
        trimmed
    end
  end

  defp selection_offset(query), do: selection_offset(query, 0, 0, :normal)

  defp selection_offset(<<>>, _index, _parens, _state), do: :decline

  defp selection_offset(<<"\"\"\"", rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + 3, parens, :block_string)

  defp selection_offset(<<"\"\"\"", rest::binary>>, index, parens, :block_string),
    do: selection_offset(rest, index + 3, parens, :normal)

  defp selection_offset(<<char::utf8, rest::binary>>, index, parens, :block_string),
    do: selection_offset(rest, index + byte_size(<<char::utf8>>), parens, :block_string)

  defp selection_offset(<<?\\, _escaped::utf8, rest::binary>>, index, parens, :string),
    do: selection_offset(rest, index + 2, parens, :string)

  defp selection_offset(<<?", rest::binary>>, index, parens, :string),
    do: selection_offset(rest, index + 1, parens, :normal)

  defp selection_offset(<<char::utf8, rest::binary>>, index, parens, :string),
    do: selection_offset(rest, index + byte_size(<<char::utf8>>), parens, :string)

  defp selection_offset(<<?\n, rest::binary>>, index, parens, :comment),
    do: selection_offset(rest, index + 1, parens, :normal)

  defp selection_offset(<<char::utf8, rest::binary>>, index, parens, :comment),
    do: selection_offset(rest, index + byte_size(<<char::utf8>>), parens, :comment)

  defp selection_offset(<<?", rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + 1, parens, :string)

  defp selection_offset(<<?#, rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + 1, parens, :comment)

  defp selection_offset(<<?(, rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + 1, parens + 1, :normal)

  defp selection_offset(<<?), rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + 1, max(parens - 1, 0), :normal)

  defp selection_offset(<<?{, _rest::binary>>, index, 0, :normal), do: {:ok, index + 1}

  defp selection_offset(<<char::utf8, rest::binary>>, index, parens, :normal),
    do: selection_offset(rest, index + byte_size(<<char::utf8>>), parens, :normal)

  @doc """
  The cost block a response reported, or `nil` when the query did not ask.

  `nil` is not an error. It is the signal that this call is being counted at an
  assumed price, which is what keeps an uninstrumented path visible in the
  coverage figure instead of silently flattering the ranking.
  """
  @spec reported(term()) :: %{optional(atom()) => term()} | nil
  def reported(%{body: body}), do: reported(body)

  def reported(%{"data" => %{"rateLimit" => %{} = rate_limit}}) do
    %{
      cost: non_negative(rate_limit["cost"]),
      remaining: non_negative(rate_limit["remaining"]),
      limit: non_negative(rate_limit["limit"]),
      reset_at: string_or_nil(rate_limit["resetAt"])
    }
  end

  def reported(_response), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  @doc """
  The call site to bill, preferring what the call site declared.

  Falls back to the GraphQL operation name and then to a REST route shape, so a
  path that forgets to declare itself lands in a named bucket rather than in
  `unattributed` — an unnamed bucket is indistinguishable from an unmeasured
  one, and the whole point of this unit is telling those apart.
  """
  @spec derive(term()) :: String.t()
  def derive(%{caller: caller}) when is_atom(caller) and not is_nil(caller), do: Atom.to_string(caller)
  def derive(%{caller: caller}) when is_binary(caller) and caller != "", do: caller

  def derive(%{body: %{"query" => query}} = request) when is_binary(query) do
    case operation_name(query) do
      nil -> route_shape(request)
      name -> "graphql:" <> name
    end
  end

  def derive(request), do: route_shape(request)

  @doc "The operation name a GraphQL document declares, or `nil`."
  @spec operation_name(term()) :: String.t() | nil
  def operation_name(query) when is_binary(query) do
    case Regex.run(~r/^\s*(?:query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)/, query) do
      [_match, name] -> name
      _anonymous -> nil
    end
  end

  def operation_name(_query), do: nil

  # A route shape, not a URL: `/repos/o/r/issues/2073/comments` and the same
  # call for #1999 are one call site and must rank as one row. Numeric and
  # sha-shaped segments collapse so the ranking counts paths, not tickets.
  @doc false
  @spec route_shape(term()) :: String.t()
  def route_shape(%{url: url} = request) when is_binary(url) do
    method = request |> Map.get(:method, :get) |> to_string() |> String.upcase()

    path =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> Kernel.||("/")
      |> String.split("/")
      |> Enum.map_join("/", &collapse_segment/1)

    "rest:" <> method <> " " <> path
  end

  def route_shape(_request), do: "unattributed"

  defp collapse_segment(segment) do
    cond do
      segment == "" -> segment
      Regex.match?(~r/^\d+$/, segment) -> ":n"
      Regex.match?(~r/^[0-9a-f]{7,40}$/, segment) -> ":sha"
      true -> segment
    end
  end
end
