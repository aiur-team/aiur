defmodule Aiur.Init.FlakeLabelTest do
  use ExUnit.Case, async: true

  test "init provisions the described flake label independently of the state prefix" do
    parent = self()
    io = %{puts: fn _ -> :ok end, input: fn _, default, _ -> default end, confirm: fn _, _ -> false end}

    deps = %{
      discover_models: fn _ -> {:error, :offline} end,
      list_labels: fn _ -> {:ok, []} end,
      create_labels: fn _, labels ->
        send(parent, {:labels, labels})
        :ok
      end
    }

    assert :ok = Aiur.Init.Labels.setup_labels(io, deps, %{kind: "github", label_prefix: "custom"}, ["claude"])
    assert_received {:labels, labels}
    assert "flake" in labels
    assert "flake" in Aiur.GitHub.Labels.label_set("custom", ["claude"])
    assert Aiur.GitHub.Labels.describe("flake") == "known intermittent test failure"
  end
end
