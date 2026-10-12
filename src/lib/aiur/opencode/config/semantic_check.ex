defmodule Aiur.Opencode.Config.SemanticCheck do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.Opencode.Config

  @impl true
  def applies?(_settings), do: true

  @impl true
  def check(_settings), do: Config.validate!()
end
