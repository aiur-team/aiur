defmodule AiurWeb.StreamdeckLive.Frame do
  @moduledoc "Adapt the emulator's retained projections to the shared daemon renderer."
  import Phoenix.Component, only: [assign: 2]
  import AiurWeb.StreamdeckLive.Env, only: [endpoint_config: 1]
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.{FrameUpdates, Render}
  alias AiurWeb.StreamdeckLive.CommandKeys

  @spec assign_frame(map()) :: map()
  def assign_frame(assigns) do
    renderer = endpoint_config(:streamdeck_render_fun) || (&Render.frame/1)

    {nav, model, frame} =
      FrameUpdates.frame(assigns.deck_nav, assigns.grid, assigns.usage, renderer, %{
        view_context: context(assigns)
      })

    assign(assigns,
      frame: frame,
      frame_model: model,
      frame_page: Nav.page(nav),
      frame_dial_value: assigns.grid_dial_value
    )
  end

  defp context(assigns) do
    %{
      active: assigns.sd_active,
      logs: assigns.logs,
      strip_entries: AiurWeb.StreamdeckStrip.entries(assigns.logs.transcript_visible),
      command_keys: command_keys(assigns),
      commands_view: assigns.commands_view,
      commands_option: assigns.commands_option,
      commands_panel: CommandKeys.commands_panel(assigns),
      decision_keys: decision_keys(assigns)
    }
  end

  defp command_keys(%{sd_ticket: ticket, mic_held?: held}) when is_map(ticket), do: CommandKeys.ticket_keys(ticket, held)
  defp command_keys(_assigns), do: CommandKeys.command_keys(nil, false)

  defp decision_keys(%{
         commands_view: :detail,
         commands_selection: selection,
         commands_offset: offset
       })
       when is_map(selection),
       do: CommandKeys.commands_option_keys(selection, offset)

  defp decision_keys(assigns), do: CommandKeys.commands_history_keys(assigns.commands, nil)
end
