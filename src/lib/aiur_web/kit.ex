defmodule AiurWeb.Kit do
  @moduledoc "Phoenix route imports for component-owned declarations, without a web-shell dependency."

  defmacro __using__(:routes) do
    quote do
      import Phoenix.Router
      import Phoenix.LiveView.Router
    end
  end
end
