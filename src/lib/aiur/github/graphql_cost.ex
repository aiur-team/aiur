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

  Two remaining imprecisions are accuracy losses, not corruption, and both show
  up in the ranking as `estimated?: true` rather than as a wrong number:

    * a document that selects `rateLimit` anywhere — including inside a nested
      selection or an argument value — is treated as already priced and left
      alone;
    * a document declaring several operations is instrumented on the first one
      only, so a request naming a later operation is billed at the assumed
      price. No such document exists in this tree; the transport sends no
      `operationName`, so a multi-operation document could not resolve at all.

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

  ## Refusing a pathological document

  A price known only after the call is a receipt, not a control, so `estimate/1`
  prices a document before it is sent: the `first:`/`last:` page sizes
  multiplied down the nesting, divided by 100. `check/2` refuses anything above
  `:github_graphql_cost_ceiling_points` and `Transport` calls it on every
  GraphQL request, so a runaway document fails at the call site with a named
  error rather than surfacing in the ranking an hour later.

  **The estimate is an upper bound on shape, not GitHub's price.** Measured
  against the reported `rateLimit { cost }` on live daemon traffic, the CI poll
  batch bills **1 point** where this arithmetic says ~510, and the comment poll
  batch bills **8 points** (at its shipped `reviewThreads(first: 20)` shape)
  where it says ~15, and billed **35** at the previous `first: 100` where it
  said ~68. GitHub evidently discounts connections that resolve to far fewer
  nodes than were requested. So the ceiling is set two orders of magnitude
  above anything this tree ships: it exists to stop a document whose *shape*
  has gone pathological — an unbounded fan-out, a page size typo — and it must
  never be tightened toward the estimate, because refusing real traffic on a
  number known to be wildly wrong is exactly the confident wrongness the
  assumed costs above produced.

  The ceiling refuses; it does not split. Splitting a document generically means
  re-planning someone else's query, and the batch callers already chunk
  themselves.

  A page size given as a variable (`first: $pageSize`) cannot be priced from the
  document, so such a document is reported as unpriceable and always allowed
  through. Those callers cap their own page size.
  """

  @selection "rateLimit { limit cost remaining resetAt }"

  # Two orders of magnitude above the largest document this tree sends (the
  # comment poll batch, ~15 by this arithmetic and 8 points in fact at its
  # shipped `reviewThreads(first: 20)` shape). See the moduledoc: this is a
  # shape guard, not a budget model.
  @default_cost_ceiling_points 20_000
  @nodes_per_point 100

  @doc "The selection injected into an uninstrumented query."
  @spec selection() :: String.t()
  def selection, do: @selection

  @doc """
  Returns `query` with a top-level `rateLimit` selection, or unchanged.

  Idempotent. See the moduledoc for the cases it declines.
  """
  @spec instrument(term()) :: term()
  def instrument(query) when is_binary(query) do
    # Word-bounded, so a field merely *named* like `rateLimitStatus` does not
    # make the document look already-priced and drop it out of the ranking.
    # A document that really does select `rateLimit` is left exactly as written.
    if Regex.match?(~r/\brateLimit\b/, query) do
      query
    else
      inject(query)
    end
  end

  def instrument(query), do: query

  # `scan/1` counts bytes, so the split must count bytes too. `String.split_at/2`
  # counts graphemes, and every multi-byte character before the brace — an em
  # dash in a comment, an accent in a search string, an emoji — would move the
  # split earlier and splice the selection into the middle of a field name,
  # turning a working query into a 400.
  defp inject(query) do
    case scan(query) do
      {:ok, offset} ->
        head = binary_part(query, 0, offset)
        tail = binary_part(query, offset, byte_size(query) - offset)
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

  defp selection_offset(<<"\\\"\"\"", rest::binary>>, index, parens, :block_string),
    do: selection_offset(rest, index + 4, parens, :block_string)

  defp selection_offset(<<"\"\"\"", rest::binary>>, index, parens, :block_string),
    do: selection_offset(rest, index + 3, parens, :normal)

  defp selection_offset(<<char::utf8, rest::binary>>, index, parens, :block_string),
    do: selection_offset(rest, index + byte_size(<<char::utf8>>), parens, :block_string)

  defp selection_offset(<<?\\, escaped::utf8, rest::binary>>, index, parens, :string),
    do: selection_offset(rest, index + 1 + byte_size(<<escaped::utf8>>), parens, :string)

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
  The points a document asks for, computed from its page sizes before sending.

  Returns `%{nodes:, points:, priceable?:}`. `points` is requested nodes divided
  by 100, never below one — an upper bound on shape, which real GitHub billing
  comes in far under (see the moduledoc). `priceable?: false` says a
  `first:`/`last:` argument was a variable, so the number is a floor and must
  not be used to refuse the call.
  """
  @spec estimate(term()) :: %{nodes: non_neg_integer(), points: pos_integer(), priceable?: boolean()}
  def estimate(query) when is_binary(query) do
    {nodes, priceable?} = query |> strip_literals() |> walk_nodes([1], nil, 0, true)

    %{nodes: nodes, points: max(div(nodes + @nodes_per_point - 1, @nodes_per_point), 1), priceable?: priceable?}
  end

  def estimate(_query), do: %{nodes: 0, points: 1, priceable?: false}

  @doc "The configured per-document ceiling, in points."
  @spec ceiling_points() :: pos_integer()
  def ceiling_points do
    case Application.get_env(:aiur, :github_graphql_cost_ceiling_points, @default_cost_ceiling_points) do
      points when is_integer(points) and points > 0 -> points
      _invalid -> @default_cost_ceiling_points
    end
  end

  @doc """
  `:ok`, or `{:error, {:graphql_cost_ceiling, details}}` for a document that asks
  for more points than the ceiling allows.

  A document whose page sizes are variables is unpriceable and always passes —
  see the moduledoc.
  """
  @spec check(term(), keyword()) :: :ok | {:error, {:graphql_cost_ceiling, map()}}
  def check(query, opts \\ []) do
    ceiling = Keyword.get(opts, :ceiling_points) || ceiling_points()
    estimate = estimate(query)

    if estimate.priceable? and estimate.points > ceiling do
      {:error,
       {:graphql_cost_ceiling,
        %{
          points: estimate.points,
          nodes: estimate.nodes,
          ceiling_points: ceiling,
          operation: operation_name(query) || "anonymous",
          caller: Keyword.get(opts, :caller)
        }}}
    else
      :ok
    end
  end

  # Strings and comments are removed first so a `first: 100` inside a body or a
  # `{` inside a comment cannot be read as structure.
  defp strip_literals(query), do: strip_literals(query, :normal, [])

  defp strip_literals(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_literals(<<"\"\"\"", rest::binary>>, :normal, acc), do: strip_literals(rest, :block_string, acc)
  defp strip_literals(<<"\"\"\"", rest::binary>>, :block_string, acc), do: strip_literals(rest, :normal, acc)
  defp strip_literals(<<_char::utf8, rest::binary>>, :block_string, acc), do: strip_literals(rest, :block_string, acc)
  defp strip_literals(<<?\\, _escaped::utf8, rest::binary>>, :string, acc), do: strip_literals(rest, :string, acc)
  defp strip_literals(<<?", rest::binary>>, :string, acc), do: strip_literals(rest, :normal, acc)
  defp strip_literals(<<_char::utf8, rest::binary>>, :string, acc), do: strip_literals(rest, :string, acc)
  defp strip_literals(<<?\n, rest::binary>>, :comment, acc), do: strip_literals(rest, :normal, [?\n | acc])
  defp strip_literals(<<_char::utf8, rest::binary>>, :comment, acc), do: strip_literals(rest, :comment, acc)
  defp strip_literals(<<?", rest::binary>>, :normal, acc), do: strip_literals(rest, :string, acc)
  defp strip_literals(<<?#, rest::binary>>, :normal, acc), do: strip_literals(rest, :comment, acc)

  defp strip_literals(<<char::utf8, rest::binary>>, :normal, acc),
    do: strip_literals(rest, :normal, [<<char::utf8>> | acc])

  # GitHub multiplies a connection's page size by the page sizes of every
  # connection enclosing it, and sums the products. `multipliers` is that
  # enclosing product as a stack, so a selection set costs whatever the argument
  # list that opened it asked for.
  defp walk_nodes(<<>>, _multipliers, _pending, nodes, priceable?), do: {nodes, priceable?}

  defp walk_nodes(<<?(, rest::binary>>, multipliers, _pending, nodes, priceable?) do
    {arguments, rest} = take_arguments(rest, 1, [])
    {pending, priceable?} = page_size(arguments, priceable?)
    walk_nodes(rest, multipliers, pending, nodes, priceable?)
  end

  # Only a paged selection set adds nodes. A plain one — `nodes`, `pageInfo`, an
  # inline fragment — is free and merely inherits its parent's multiplier, which
  # is why it pushes 1 instead of counting itself.
  defp walk_nodes(<<?{, rest::binary>>, multipliers, nil, nodes, priceable?),
    do: walk_nodes(rest, [1 | multipliers], nil, nodes, priceable?)

  defp walk_nodes(<<?{, rest::binary>>, multipliers, page, nodes, priceable?) when is_integer(page),
    do: walk_nodes(rest, [page | multipliers], nil, nodes + page * Enum.product(multipliers), priceable?)

  defp walk_nodes(<<?}, rest::binary>>, [_page | multipliers], _pending, nodes, priceable?)
       when multipliers != [],
       do: walk_nodes(rest, multipliers, nil, nodes, priceable?)

  defp walk_nodes(<<?}, rest::binary>>, multipliers, _pending, nodes, priceable?),
    do: walk_nodes(rest, multipliers, nil, nodes, priceable?)

  defp walk_nodes(<<_char::utf8, rest::binary>>, multipliers, pending, nodes, priceable?),
    do: walk_nodes(rest, multipliers, pending, nodes, priceable?)

  defp take_arguments(<<>>, _depth, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_arguments(<<?), rest::binary>>, 1, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_arguments(<<?), rest::binary>>, depth, acc), do: take_arguments(rest, depth - 1, [?) | acc])
  defp take_arguments(<<?(, rest::binary>>, depth, acc), do: take_arguments(rest, depth + 1, [?( | acc])

  defp take_arguments(<<char::utf8, rest::binary>>, depth, acc),
    do: take_arguments(rest, depth, [<<char::utf8>> | acc])

  # A page size given as a variable cannot be priced here. It is reported rather
  # than guessed at, and `check/2` declines to refuse such a document.
  defp page_size(arguments, priceable?) do
    case Regex.run(~r/\b(?:first|last)\s*:\s*(\$?[A-Za-z_0-9]+)/, arguments) do
      nil -> {nil, priceable?}
      [_match, "$" <> _variable] -> {nil, false}
      [_match, literal] -> literal_page_size(literal, priceable?)
    end
  end

  defp literal_page_size(literal, priceable?) do
    case Integer.parse(literal) do
      {size, ""} when size > 0 -> {size, priceable?}
      _other -> {nil, false}
    end
  end

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

  A GraphQL request is never billed to a `rest:` row, even when its document is
  anonymous. The transport dimension is part of what the row is read for, so
  mislabelling it is worse than admitting the operation is unnamed.
  """
  @spec derive(term()) :: String.t()
  def derive(%{caller: caller}) when is_atom(caller) and not is_nil(caller), do: Atom.to_string(caller)
  def derive(%{caller: caller}) when is_binary(caller) and caller != "", do: caller

  def derive(%{body: %{"query" => query}}) when is_binary(query) do
    case operation_name(query) do
      nil -> "graphql:anonymous"
      name -> "graphql:" <> name
    end
  end

  def derive(request), do: route_shape(request)

  @doc "The operation name a GraphQL document declares, or `nil`."
  @spec operation_name(term()) :: String.t() | nil
  def operation_name(query) when is_binary(query) do
    # Leading comments are stripped first: the anchor cannot skip them, and a
    # document whose name is hidden behind a `#` line would otherwise rank as
    # anonymous.
    stripped = strip_leading_trivia(query)

    case Regex.run(~r/^(?:query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)/, stripped) do
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
