defmodule VoiceConverse.Briefing do
  @moduledoc """
  Generic status card for one target, filled by the host's `BriefingSource`.

  Fields typed `field/1` carry `%{value, observed_at, max_age_s}`. A `nil` field means the host
  has no data and renders as "not reported", never as an empty value that reads as "idle".
  An empty value (`""` or `[]`) is a stated "none".

  `render/2` builds the text block the assistant reads, `diff/2` the changed lines for one
  non-interrupting context update, and `from_markdown/2` parses the fixed-heading Markdown an
  agent writes. Rendering does not redact; the context builder applies the redactor hook.
  """

  alias VoiceConverse.Briefing.{Lines, Markdown}

  @type field(t) :: %{value: t, observed_at: DateTime.t(), max_age_s: pos_integer() | nil}

  @type t :: %__MODULE__{
          version: pos_integer(),
          summary: field(String.t()) | nil,
          current_task: field(String.t()) | nil,
          next_steps: field([String.t()]) | nil,
          waiting_on: field(String.t()) | nil,
          questions: field([String.t()]) | nil,
          links: [%{label: String.t(), url: String.t()}],
          extra: [%{title: String.t(), text: String.t(), observed_at: DateTime.t()}],
          gaps: [String.t()]
        }

  @type meta :: %{tokens: non_neg_integer(), dropped: [:extra | :links | :next_steps], over_budget: boolean()}

  defstruct version: 1,
            summary: nil,
            current_task: nil,
            next_steps: nil,
            waiting_on: nil,
            questions: nil,
            links: [],
            extra: [],
            gaps: []

  # Matches the `Config` default for `limits.briefing_token_budget`; callers holding a config
  # pass `budget: config.limits.briefing_token_budget`.
  @default_budget 1_500
  @drop_order [:extra, :links, :next_steps]
  @kept_next_steps 3

  @doc """
  Renders the briefing as text within a token budget.

  Options: `:budget` (tokens, default #{@default_budget}; pass
  `Config.limits.briefing_token_budget` to follow a configured limit) and `:now` (default
  `DateTime.utc_now/0`; inject it for deterministic ages). Tokens are estimated as
  `div(byte_size(text), 4)`. Over budget, it drops `extra`, then `links`, then `next_steps`
  beyond #{@kept_next_steps}, stopping as soon as the text fits. `summary`, `current_task`,
  `waiting_on`, `questions` and `gaps` are never dropped or cut: if they alone exceed the budget
  the text stays whole and `over_budget` is `true`.
  """
  @spec render(t(), keyword()) :: {String.t(), meta()}
  def render(%__MODULE__{} = briefing, opts \\ []) do
    budget = Keyword.get(opts, :budget, @default_budget)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    {text, dropped} =
      @drop_order
      |> drop_steps()
      |> Enum.reduce_while(nil, fn dropped, _acc ->
        text = briefing |> drop(dropped) |> Lines.build() |> Lines.to_text(now)
        if estimate(text) <= budget, do: {:halt, {text, dropped}}, else: {:cont, {text, dropped}}
      end)

    tokens = estimate(text)
    dropped = Enum.filter(dropped, &(drop_one(&1, briefing) != briefing))
    {text, %{tokens: tokens, dropped: dropped, over_budget: tokens > budget}}
  end

  @doc """
  Lines that changed from `old` to `new`, one per field, without age text.

  `version`, `observed_at` and the passing of time never produce a line, so a periodic refresh
  with the same content sends nothing. A field whose value became empty, and a links, gaps or
  extra line that disappeared, yields `"<Field>: none now"`; a field that became `nil` yields its
  rendered `"<Field>: not reported"` line.
  """
  @spec diff(t(), t()) :: [String.t()]
  def diff(%__MODULE__{} = old, %__MODULE__{} = new) do
    old_lines = Map.new(Lines.build(old), &{&1.key, &1})
    new_lines = Lines.build(new)
    new_keys = MapSet.new(new_lines, & &1.key)

    changed =
      for line <- new_lines, Map.get(old_lines, line.key, %{text: nil}).text != line.text do
        if line.empty?, do: "#{line.label}: none now", else: line.text
      end

    removed =
      for line <- Lines.build(old), not MapSet.member?(new_keys, line.key), do: "#{line.label}: none now"

    changed ++ removed
  end

  @doc """
  Parses a Markdown briefing with the headings Summary, Doing now, Next, Waiting on and
  Questions for you. See `VoiceConverse.Briefing.Markdown`.
  """
  @spec from_markdown(String.t(), DateTime.t() | nil) :: t()
  def from_markdown(markdown, observed_at \\ nil),
    do: Markdown.parse(markdown, observed_at || DateTime.utc_now())

  defp drop_steps(order), do: for(n <- 0..length(order), do: Enum.take(order, n))

  defp drop(briefing, dropped), do: Enum.reduce(dropped, briefing, &drop_one/2)

  defp drop_one(:extra, b), do: %{b | extra: []}
  defp drop_one(:links, b), do: %{b | links: []}
  defp drop_one(:next_steps, %{next_steps: nil} = b), do: b

  defp drop_one(:next_steps, %{next_steps: field} = b),
    do: %{b | next_steps: %{field | value: Enum.take(field.value, @kept_next_steps)}}

  defp estimate(text), do: div(byte_size(text), 4)
end
