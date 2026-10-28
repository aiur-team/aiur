defmodule AiurWeb.StreamdeckLive.ImageComponents do
  @moduledoc "Browser wrappers for trusted images produced by Streamdeck.Render."

  use Phoenix.Component

  attr(:image, :map, default: nil)
  attr(:index, :integer, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  @spec key(map()) :: Phoenix.LiveView.Rendered.t()
  def key(assigns) do
    ~H"""
    <button
      type="button"
      class={["sd-key", @class, is_nil(@image) && "is-empty"]}
      style="width: 120px; height: 120px; padding: 0;"
      data-streamdeck-key={@index}
      disabled={is_nil(@image)}
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

  @spec grid(map()) :: Phoenix.LiveView.Rendered.t()
  def grid(assigns) do
    {faces, _regions} = AiurWeb.Streamdeck.Render.Grid.compose(assigns.model)
    assigns = assign(assigns, :slots, Enum.zip(assigns.frame.keys, faces) |> Enum.with_index())

    ~H"""
    <div id="sd-keys" class="sd-keys" role="group" aria-label="Agent keys" data-mode-view="grid"
      data-grid-total={@grid.total} data-grid-windows={@grid.windows} data-grid-page={@page}
      data-grid-page-count={@grid.windows} data-grid-column-offset={@page * 4}
      data-grid-dial-value={@dial_value} data-grid-selected-identifier={@selected_identifier}>
      <.key :for={{{image, face}, index} <- @slots} image={image} index={index} class="sd-agent-key"
        data-streamdeck-identifier={face && face.identifier} data-streamdeck-state={face && face.bucket} data-control-action={face && control_action(face.bucket)} />
    </div>
    """
  end

  defp control_action(bucket) when bucket in [:running, "running"], do: "pause"
  defp control_action(bucket) when bucket in [:paused, "paused"], do: "resume"
  defp control_action(_bucket), do: nil

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
