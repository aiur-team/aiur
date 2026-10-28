defmodule AiurWeb.StreamdeckLive.ImageComponents do
  @moduledoc "Browser wrappers for trusted images produced by Streamdeck.Render."

  use Phoenix.Component

  attr(:image, :map, default: nil)
  attr(:index, :integer, required: true)
  attr(:class, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:rest, :global)

  @spec key(map()) :: Phoenix.LiveView.Rendered.t()
  def key(assigns) do
    ~H"""
    <button
      type="button"
      class={["sd-key", @class, is_nil(@image) && "is-empty"]}
      style="width: 120px; height: 120px; padding: 0;"
      data-streamdeck-key={@index}
      disabled={is_nil(@image) or @disabled}
      aria-disabled={to_string(is_nil(@image) or @disabled)}
      aria-hidden={is_nil(@image) && "true"}
      aria-label={@image && @image.label}
      {@rest}
    >
      {if @image, do: Phoenix.HTML.raw(@image.svg)}
    </button>
    """
  end

  attr(:frame, :map, required: true)
  attr(:model, :map, required: true)
  attr(:grid, :map, required: true)
  attr(:page, :integer, required: true)
  attr(:dial_value, :integer, required: true)
  attr(:selected_identifier, :any, default: nil)
  attr(:mode, :atom, required: true)
  attr(:logs, :map, required: true)
  attr(:commands_view, :atom, required: true)

  @spec keys(map()) :: Phoenix.LiveView.Rendered.t()
  def keys(assigns) do
    {faces, _regions} = AiurWeb.Streamdeck.Render.compose(assigns.model)
    assigns = assign(assigns, :slots, Enum.zip(assigns.frame.keys, faces) |> Enum.with_index())

    ~H"""
    <div id={container_id(@mode)} data-mode-view={@mode} data-focused-identifier={@selected_identifier}>
      <div id={keys_id(@mode)} class="sd-keys" role="group" aria-label={keys_label(@mode)} data-mode-view={@mode}
        data-grid-total={@mode == :grid && @grid.total} data-grid-windows={@mode == :grid && @grid.windows}
        data-grid-page={@mode == :grid && @page} data-grid-page-count={@mode == :grid && @grid.windows}
        data-grid-column-offset={@mode == :grid && @page * 4} data-grid-dial-value={@mode == :grid && @dial_value}
        data-grid-selected-identifier={@mode == :grid && @selected_identifier} data-commands-view={@mode == :commands && @commands_view}
        data-offset={@mode == :logs && @logs.events_offset} data-max-offset={@mode == :logs && @logs.events_max_offset}>
        <.key :for={{{image, face}, index} <- @slots} image={image} index={index} class={key_class(@mode, face)} disabled={value(face, :disabled, false)}
          data-streamdeck-identifier={if @mode == :grid, do: value(face, :identifier), else: if(@mode == :cmd, do: @selected_identifier)}
          data-streamdeck-state={value(face, :bucket)} data-control-action={control_action(value(face, :bucket))}
          data-streamdeck-command={value(face, :command)} data-streamdeck-icon={value(face, :icon)}
          data-command-state={value(face, :state)} data-command-hold={value(face, :hold) && "true"}
          data-command-label={value(face, :title)} data-command-sub={value(face, :sub)}
          data-log-event-index={value(face, :event_index)} aria-current={if @mode == :logs, do: to_string(value(face, :selected, false))}
          data-command-key={value(face, :decision_id)} data-command-option={@commands_view == :detail && value(face, :option_index)}
          data-command-selected={value(face, :selected) && "true"}
          phx-click={not is_nil(value(face, :option_index)) && "command-select"} phx-value-index={value(face, :option_index)} />
      </div>
      <div :if={@mode == :logs} hidden>
        <div id="sd-log-events" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
          <span id="sd-events-hint-up" aria-hidden={to_string(@logs.events_offset == 0)}>↑</span>
          <span id="sd-events-hint-down" aria-hidden={to_string(@logs.events_offset >= @logs.events_max_offset)}>↓</span>
        </div>
        <div id="sd-log-transcript" data-offset={@logs.transcript_offset} data-max-offset={@logs.transcript_max_offset}>
          <span id="sd-transcript-hint-up" aria-hidden={to_string(@logs.transcript_offset == 0)}>↑</span>
          <span id="sd-transcript-hint-down" aria-hidden={to_string(@logs.transcript_offset >= @logs.transcript_max_offset)}>↓</span>
        </div>
      </div>
    </div>
    """
  end

  defp value(nil, _key, default), do: default
  defp value(face, key, default), do: Map.get(face, key, default)
  defp value(face, key), do: value(face, key, nil)
  defp control_action(bucket) when bucket in [:running, "running"], do: "pause"
  defp control_action(bucket) when bucket in [:paused, "paused"], do: "resume"
  defp control_action(_bucket), do: nil
  defp container_id(:grid), do: nil
  defp container_id(:cmd), do: nil
  defp container_id(mode), do: "sd-#{mode}-view"
  defp keys_id(:logs), do: "sd-log-keys"
  defp keys_id(:commands), do: "sd-command-keys"
  defp keys_id(_mode), do: "sd-keys"
  defp keys_label(:grid), do: "Agent keys"
  defp keys_label(:cmd), do: "Available commands"
  defp keys_label(:logs), do: "Log event keys"
  defp keys_label(:commands), do: "Command keys"
  defp keys_label(:settings), do: "Settings"

  defp key_class(mode, face) do
    [
      if(mode == :grid, do: "sd-agent-key"),
      if(mode == :cmd, do: "sd-cmd-key"),
      if(mode == :logs, do: "sd-log-key"),
      value(face, :hold, false) && "sd-mic-key",
      value(face, :state) == "live" && "mic-live",
      value(face, :live, false) && "sd-live-key",
      value(face, :selected, false) && "is-selected"
    ]
  end

  attr(:regions, :list, required: true)
  attr(:rest, :global)

  @spec strip(map()) :: Phoenix.LiveView.Rendered.t()
  def strip(assigns) do
    ~H"""
    <div id="sd-screen" class="sd-screen" role="group" aria-label="Touch strip" style="position: relative; width: 800px; height: 100px;" {@rest}>
      <div
        :for={region <- @regions}
        data-streamdeck-region={region.x}
        role="img"
        aria-label={region.label}
        style={"position: absolute; left: #{region.x}px; width: #{region.width}px; height: 100px;"}
      >
        {Phoenix.HTML.raw(region.svg)}
      </div>
    </div>
    """
  end
end
