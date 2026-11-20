defmodule AiurWeb.Routes.Experiments do
  @moduledoc "Experiment route definitions expanded inside the shared dashboard session."
  use AiurWeb.Kit, :routes

  defmacro pages do
    quote do
      live("/experiments", AiurWeb.ExperimentsLive, :experiments)
      live("/experiments/:id", AiurWeb.ExperimentsLive, :experiment)
    end
  end
end
