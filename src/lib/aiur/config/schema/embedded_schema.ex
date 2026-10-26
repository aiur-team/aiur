defmodule Aiur.Config.Schema.EmbeddedSchema do
  @moduledoc false

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(resources) do
    quote bind_quoted: [resources: resources] do
      use Ecto.Schema

      for source <- resources do
        @external_resource Path.join(__DIR__, source)
      end
    end
  end
end
