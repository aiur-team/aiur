defmodule Aiur.GitHub.Config.SemanticCheck do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.GitHub.Config

  @impl true
  def applies?(settings), do: settings.tracker.kind == "github"

  @impl true
  def check(_settings), do: Config.validate!()
end
