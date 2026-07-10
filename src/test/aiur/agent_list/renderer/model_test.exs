defmodule Aiur.AgentList.Renderer.ModelTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Model

  test "resolves model families and display values" do
    assert Model.model_family(%{model: "opus-4-8"}) == :opus
    assert Model.model_family(%{backend: "claude-repl"}) == :claude
    assert Model.model_full_name(:sonnet, "sonnet-4-6") == "Claude Sonnet 4.6"
    assert Model.model_full_name(:codex, "gpt-5.5") == "Codex GPT-5.5"
    assert Model.model_color(:opus, true) == "\e[38;2;198;155;255m"
    assert Model.model_color(:haiku, false) == nil
    assert Model.base_width() == 6
  end
end
