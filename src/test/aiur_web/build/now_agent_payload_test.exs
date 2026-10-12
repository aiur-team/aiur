defmodule AiurWeb.Build.NowAgentPayloadTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Payload

  test "agent model may be null" do
    assert Payload.validate(with_agent("model", nil)) == :ok
  end

  test "agent name is a required short string or null" do
    for name <- ["Muse", nil, String.duplicate("界", 64)], do: assert(Payload.validate(with_agent("name", name)) == :ok)

    for name <- [7, String.duplicate("a", 65)] do
      assert {:error, errors} = Payload.validate(with_agent("name", name))
      assert Enum.any?(errors, fn {path, _reason} -> path == "sections.now.0.agent.name" end)
    end

    data = update_in(fixture(), ["sections", "now", Access.at(0), "agent"], &Map.delete(&1, "name"))
    assert {:error, errors} = Payload.validate(data)
    assert {"sections.now.0.agent.name", :missing} in errors
  end

  test "agent effort uses the full product vocabulary" do
    for effort <- ~w(none minimal low medium high xhigh max), do: assert(Payload.validate(with_agent("effort", effort)) == :ok)
    assert {:error, errors} = Payload.validate(with_agent("effort", "ultra"))
    assert {"sections.now.0.agent.effort", :enum} in errors
  end

  test "regenerated fixtures carry agent names" do
    for dataset <- ~w(live dense newrepo noqueue offline) do
      {:ok, data} = FixtureSource.full(dataset: dataset)

      for row <- data["sections"] |> Map.values() |> List.flatten(), row["agent"] != nil do
        assert Map.fetch!(row["agent"], "name") in ~w(Claude Codex DeepSeek Kimi)
      end
    end
  end

  defp with_agent(key, value), do: put_in(fixture(), ["sections", "now", Access.at(0), "agent", key], value)

  defp fixture do
    {:ok, data} = FixtureSource.full(dataset: "live")
    data
  end
end
