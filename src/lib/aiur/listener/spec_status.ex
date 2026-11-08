defmodule Aiur.Listener.SpecStatus do
  @moduledoc false

  @spec read() :: term()
  def read do
    module = Module.concat(["Aiur", "Listener", "Spec"])
    if Code.ensure_loaded?(module), do: module.status(), else: {:error, :not_installed}
  end
end
