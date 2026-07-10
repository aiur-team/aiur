defmodule Aiur.AgentList.Renderer.ModelTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Model

  test "resolves model families and display values" do
    assert Model.model_family(%{model: "opus-4-8"}) == :opus
    assert Model.model_family(%{backend: "claude-repl"}) == :claude
    assert Model.model_full_name(:sonnet, "sonnet-4-6") == "Claude Sonnet 4.6"
    assert Model.base_width() == 6
  end
end
