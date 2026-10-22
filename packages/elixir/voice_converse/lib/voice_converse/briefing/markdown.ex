defmodule VoiceConverse.Briefing.Markdown do
  @moduledoc """
  Parses the fixed-heading Markdown briefing an agent writes into a `VoiceConverse.Briefing`.

  Headings match at any level, ignoring case and a trailing colon. Each field accepts the
  canonical heading and the aliases below; there is no fuzzy matching. Agent-facing text should
  use the canonical headings: Summary, Doing now, Next, Waiting on, Questions for you.

  Under Next and Questions for you, each non-empty line is one entry (a leading `-`, `*`, `+`
  or `1.` marker is removed); a heading with no entries means "none". Other fields join their
  lines with spaces. An unknown heading becomes an `extra` entry, which `render/2` drops first.
  A missing heading leaves the field `nil` and adds a `gaps` entry; it is not an error. Parsed
  fields get the given `observed_at` and `max_age_s: nil`; the host sets freshness limits.
  """

  alias VoiceConverse.Briefing
  alias VoiceConverse.Briefing.Lines

  @aliases %{
    summary: ["summary"],
    current_task: ["doing now", "current task", "now"],
    next_steps: ["next", "next steps"],
    waiting_on: ["waiting on", "waiting for", "blocked on"],
    questions: ["questions for you", "questions", "asks"]
  }
  @list_fields [:next_steps, :questions]

  @heading ~r/^\s{0,3}\#{1,6}\s+(.*?)\s*#*\s*$/
  @fence ~r/^\s{0,3}(```|~~~)/
  @bullet ~r/^\s*(?:[-*+]|\d+[.)])\s+/

  @spec aliases() :: %{atom() => [String.t()]}
  def aliases, do: @aliases

  @spec parse(String.t(), DateTime.t()) :: Briefing.t()
  def parse(markdown, %DateTime{} = observed_at) do
    sections = sections(markdown)
    lookup = for {key, names} <- @aliases, name <- names, into: %{}, do: {name, key}
    {known, unknown} = Enum.split_with(sections, fn {title, _} -> Map.has_key?(lookup, normalize(title)) end)
    found = Map.new(known, fn {title, body} -> {Map.fetch!(lookup, normalize(title)), body} end)

    fields =
      for {key, _label} <- Lines.fields(), Map.has_key?(found, key) do
        {key, %{value: value(key, found[key]), observed_at: observed_at, max_age_s: nil}}
      end

    gaps = for {key, label} <- Lines.fields(), not Map.has_key?(found, key), do: "no \"#{label}\" section"
    extra = for {title, body} <- unknown, do: %{title: title, text: join(body), observed_at: observed_at}

    struct(Briefing, fields ++ [extra: extra, gaps: gaps])
  end

  # Returns [{heading, [body lines]}] in document order; text before the first heading is ignored.
  # A `#` line inside a fenced code block is body text, not a heading.
  defp sections(markdown) do
    markdown
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({false, []}, &section_line/2)
    |> elem(1)
    |> Enum.map(fn {title, body} -> {title, Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  defp section_line(line, {in_fence?, acc}) do
    cond do
      Regex.match?(@fence, line) -> {not in_fence?, append(acc, line)}
      in_fence? -> {true, append(acc, line)}
      match = Regex.run(@heading, line) -> {false, [{Enum.at(match, 1), []} | acc]}
      true -> {false, append(acc, line)}
    end
  end

  defp append([], _line), do: []
  defp append([{title, body} | rest], line), do: [{title, [line | body]} | rest]

  defp normalize(title), do: title |> String.trim() |> String.trim_trailing(":") |> String.trim() |> String.downcase()

  defp value(key, body) when key in @list_fields do
    for line <- body, item = line |> String.replace(@bullet, "") |> String.trim(), item != "", do: item
  end

  defp value(_key, body), do: join(body)

  defp join(body), do: body |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
end
