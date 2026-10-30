defmodule AiurWeb.Streamdeck.Deck.Nav do
  @moduledoc """
  Pure per-deck navigation. Indexes are zero-based; one page holds eight keys.

  Callers resolve keys against server-owned sections and attach an atom-keyed
  `:target` tuple `{kind, id}`; device-supplied targets are never trusted.
  Clients classify a 500 ms hold as one `dial_long_press`, suppressing the
  release `dial_press`. Effects are data for ticket/priority action owners.
  """

  @views [:ticket, :feature, :epic, :fleet]
  defstruct surface: :grid,
            settings: %{section: nil, cursor: 0, return_surface: :grid, notice: nil},
            view: :ticket,
            pages: %{ticket: 0, feature: 0, epic: 0, fleet: 0},
            stack: [],
            drill_pages: [],
            selected: nil,
            chat: nil,
            scroll: 0,
            chip_offset: 0,
            meter_count: 0

  @type t :: %__MODULE__{
          view: :ticket | :feature | :epic | :fleet,
          surface: :grid | :chat | :cmd | :settings | :commands,
          settings: map(),
          pages: map(),
          stack: [{atom(), String.t()}],
          drill_pages: [non_neg_integer()],
          selected: String.t() | nil,
          chat: map() | nil,
          scroll: non_neg_integer(),
          chip_offset: non_neg_integer(),
          meter_count: non_neg_integer()
        }
  @type effect :: {:chat_page, String.t()} | :close_ticket | {:open_ticket, String.t()} | {:priority, String.t(), :up | :down, pos_integer()} | {:settings_set, map()}

  @spec valid_input?(term()) :: boolean()
  def valid_input?(%{"kind" => "key_press", "index" => index}),
    do: is_integer(index) and index in 0..7

  def valid_input?(%{"kind" => kind, "index" => index} = input)
      when kind in ["dial_press", "dial_long_press", "dial_turn"] do
    is_integer(index) and index in 0..3 and valid_ticks?(kind, input)
  end

  def valid_input?(_input), do: false

  @spec reduce(t(), map(), map()) :: {t(), [effect()]} | {:error, %{reason: String.t()}}
  def reduce(%__MODULE__{} = nav, input, sizes) do
    if valid_input?(input) do
      nav = clamp(nav, sizes)
      {nav, effects} = transition(nav, input)
      {clamp(nav, sizes), effects}
    else
      {:error, %{reason: "invalid_input"}}
    end
  end

  @spec page(t()) :: non_neg_integer()
  def page(%{stack: [], pages: pages, view: view}), do: Map.fetch!(pages, view)
  def page(%{drill_pages: [page | _rest]}), do: page

  @spec clamp(t(), map()) :: t()
  def clamp(nav, sizes) do
    pages =
      Map.new(nav.pages, fn {view, page} -> {view, clamp_page(page, Map.get(sizes, view, 0))} end)

    drill_pages =
      case nav.drill_pages do
        [page | rest] -> [clamp_page(page, Map.get(sizes, :drill) || 0) | rest]
        [] -> []
      end

    %{nav | pages: pages, drill_pages: drill_pages, chip_offset: min(nav.chip_offset, Map.get(sizes, :chip_max_offset, 0))}
  end

  defp valid_ticks?("dial_turn", %{"ticks" => ticks}), do: is_integer(ticks) and ticks in -32..32
  defp valid_ticks?("dial_turn", _input), do: false
  defp valid_ticks?(_kind, _input), do: true

  defp transition(nav, %{"kind" => "dial_press", "index" => 3}) do
    next = rem(Enum.find_index(@views, &(&1 == nav.view)) + 1, length(@views))
    {%{nav | view: Enum.at(@views, next), stack: [], drill_pages: [], scroll: 0, selected: nil}, []}
  end

  defp transition(%{stack: [_entry | rest], drill_pages: [_page | pages]} = nav, %{
         "kind" => "dial_long_press",
         "index" => 3
       }),
       do: {%{nav | stack: rest, drill_pages: pages, scroll: 0}, []}

  defp transition(nav, %{"kind" => "dial_turn", "index" => 3, "ticks" => ticks}),
    do: {put_page(nav, page(nav) + ticks), []}

  defp transition(nav, %{"kind" => "dial_turn", "index" => 0, "ticks" => ticks}),
    do: {%{nav | scroll: max(nav.scroll + ticks, 0)}, []}

  defp transition(%{stack: [{:meter_detail, _provider} | _]} = nav, %{"kind" => "dial_turn", "index" => 1}), do: {nav, []}

  defp transition(%{selected: id} = nav, %{"kind" => "dial_turn", "index" => 1, "ticks" => ticks})
       when is_binary(id) and ticks != 0,
       do: {nav, [{:priority, id, if(ticks < 0, do: :up, else: :down), abs(ticks)}]}

  defp transition(%{selected: nil} = nav, %{"kind" => "dial_turn", "index" => 1, "ticks" => ticks}),
    do: {%{nav | chip_offset: max(nav.chip_offset + ticks, 0)}, []}

  defp transition(nav, %{"kind" => "key_press", target: {:ticket, id}}) when is_binary(id),
    do: {%{nav | selected: id}, [{:open_ticket, id}]}

  defp transition(nav, %{"kind" => "key_press", target: {kind, id}}) when kind in [:feature, :epic, :fleet, :meter_detail] and is_binary(id),
    do: {%{nav | stack: [{kind, id} | nav.stack], drill_pages: [0 | nav.drill_pages], scroll: 0}, []}

  defp transition(nav, _input), do: {nav, []}

  defp put_page(%{stack: []} = nav, page),
    do: %{nav | pages: Map.put(nav.pages, nav.view, page), scroll: 0}

  defp put_page(%{drill_pages: [_page | rest]} = nav, page),
    do: %{nav | drill_pages: [page | rest], scroll: 0}

  defp clamp_page(page, size), do: page |> max(0) |> min(max(div(max(size, 0) + 7, 8) - 1, 0))
end
