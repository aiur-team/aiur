defmodule AiurWeb.StreamdeckLive.ImageComponents do
  @moduledoc "Browser wrappers for trusted images produced by Streamdeck.Render."

  use Phoenix.Component

  attr(:image, :map, default: nil)
  attr(:index, :integer, required: true)
  attr(:rest, :global)

  @spec key(map()) :: Phoenix.LiveView.Rendered.t()
  def key(assigns) do
    ~H"""
    <button
      type="button"
      class={["sd-key", is_nil(@image) && "is-empty"]}
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
