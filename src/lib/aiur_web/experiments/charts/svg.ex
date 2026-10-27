defmodule AiurWeb.Experiments.Charts.Svg do
  @moduledoc false

  @spec escape(term()) :: String.t()
  def escape(value), do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @spec number(term()) :: String.t()
  def number(value) when is_number(value) and value != 0 and abs(value) < 0.01, do: :erlang.float_to_binary(value / 1, scientific: 2)
  def number(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2) |> String.trim_trailing("0") |> String.trim_trailing(".")
  def number(_), do: "Unavailable"

  @spec wrap(String.t(), number(), iodata()) :: String.t()
  def wrap(label, height, body) do
    ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 #{height}" width="100%" role="img" aria-label="#{escape(label)}">#{IO.iodata_to_binary(body)}</svg>)
  end

  @spec line(number(), number(), number(), number(), String.t()) :: String.t()
  def line(x1, y1, x2, y2, class \\ ""),
    do: ~s(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="currentColor" class="#{escape(class)}" />)

  @spec text(number(), number(), term()) :: String.t()
  def text(x, y, value), do: ~s(<text x="#{x}" y="#{y}" fill="currentColor" font-size="12">#{escape(value)}</text>)

  @spec rect(number(), number(), number(), number(), String.t()) :: String.t()
  def rect(x, y, width, height, class), do: ~s(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" class="#{escape(class)}" />)

  @spec marker(number(), number(), non_neg_integer(), String.t()) :: String.t()
  def marker(x, y, index, class \\ "exp-point") do
    body = shape(x, y, index)
    ~s(<g class="#{escape(class)} exp-series-#{rem(index, 4)}">#{body}</g>)
  end

  defp shape(x, y, 0), do: ~s(<circle cx="#{x}" cy="#{y}" r="4" />)
  defp shape(x, y, 1), do: ~s(<rect x="#{x - 4}" y="#{y - 4}" width="8" height="8" />)
  defp shape(x, y, 2), do: ~s(<path d="M #{x} #{y - 5} L #{x - 5} #{y + 4} L #{x + 5} #{y + 4} Z" />)
  defp shape(x, y, 3), do: ~s(<path d="M #{x} #{y - 5} L #{x - 5} #{y} L #{x} #{y + 5} L #{x + 5} #{y} Z" />)

  defp shape(x, y, index), do: ~s(<text x="#{x}" y="#{y + 3}" text-anchor="middle" font-size="9">#{index + 1}</text>)

  @spec domain([number()], String.t()) :: {number(), number()}
  def domain(values, scale \\ "linear") do
    values = Enum.filter(values, &(is_number(&1) and (scale != "log" or &1 > 0)))
    expand(Enum.min(values, fn -> if(scale == "log", do: 1, else: 0) end), Enum.max(values, fn -> 1 end), scale)
  end

  defp expand(value, value, "log"), do: {value / 10, value * 10}
  defp expand(value, value, _scale), do: {value - 1, value + 1}
  defp expand(lo, hi, _scale), do: {lo, hi}

  @spec position(number(), {number(), number()}, {number(), number()}, String.t()) :: number()
  def position(value, {lo, hi}, {start, stop}, scale \\ "linear") do
    {value, lo, hi} = if scale == "log", do: {:math.log10(value), :math.log10(lo), :math.log10(hi)}, else: {value, lo, hi}
    start + (value - lo) / (hi - lo) * (stop - start)
  end

  @spec ticks({number(), number()}, String.t()) :: [number()]
  def ticks({lo, hi}, "log"), do: for(exponent <- floor(:math.log10(lo))..ceil(:math.log10(hi)), value = :math.pow(10, exponent), value >= lo and value <= hi, do: value)

  def ticks({lo, hi}, _scale) do
    power = :math.pow(10, floor(:math.log10((hi - lo) / 4)))
    factor = Enum.find([1, 2, 2.5, 5, 10], &(&1 * power >= (hi - lo) / 4))
    step = factor * power
    for index <- ceil(lo / step)..floor(hi / step), do: index * step
  end

  @spec table(String.t(), [String.t()], [[term()]]) :: String.t()
  def table(caption, headings, rows) do
    header = Enum.map_join(headings, &"<th scope=\"col\">#{escape(&1)}</th>")
    body = Enum.map_join(rows, fn row -> "<tr>" <> Enum.map_join(row, &"<td>#{escape(&1)}</td>") <> "</tr>" end)
    ~s(<details><summary>Show data</summary><div class="exp-data-scroll"><table><caption>#{escape(caption)}</caption><thead><tr>#{header}</tr></thead><tbody>#{body}</tbody></table></div></details>)
  end
end
