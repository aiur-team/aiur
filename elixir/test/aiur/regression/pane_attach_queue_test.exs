defmodule Aiur.Regression.PaneAttachQueueTest do
  @moduledoc """
  Regression coverage for the three bugs + one model shift from
  `elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md`.

  Unit-level AEs are covered here. AE2 (boot race repro), AE5 (manual
  attach with two identifiers in models map), AE6 (attach keybind UX),
  and AE7 (60 s timeout) require a live SlotSupervisor + opencode-serve
  and are covered by manual CLI verification in U8.
  """

  use ExUnit.Case, async: true

  alias Aiur.Opencode.{Protocol, WorkspaceSetup}

  describe "AE1: chat chrome shows agent identifier, not literal Aiur" do
    test "every model declared in the slot's opencode.json has name = key" do
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://127.0.0.1:4097",
          bridge_token: "secret",
          identifier: "_slot-1",
          opencode_os_pid: nil,
          extra_identifiers: ["13", "17", "12"]
        })

      models = get_in(config, ["provider", "aiur", "models"])

      for {key, %{"name" => name}} <- models do
        assert key == name,
               "AE1: model key #{inspect(key)} must have name=#{inspect(key)} but had name=#{inspect(name)}"
      end

      # And no model declares the literal "Aiur" anywhere as its name.
      names = models |> Map.values() |> Enum.map(& &1["name"])
      refute "Aiur" in names, "AE1: model display name regression: #{inspect(names)}"
    end
  end

  describe "AE3: slot materializes empty models map at boot" do
    test "WorkspaceSetup.materialize_slot/5 with empty identifiers writes only the slot sentinel" do
      workspace = Path.join(System.tmp_dir!(), "aiur-ae3-#{System.unique_integer([:positive])}")
      _ = File.rm_rf(workspace)

      try do
        {:ok, _token} =
          WorkspaceSetup.materialize_slot(workspace, "http://127.0.0.1:4097", [], 1, 1)

        config_path = Path.join(workspace, "opencode.json")
        assert File.exists?(config_path), "AE3: opencode.json must be written"

        config = config_path |> File.read!() |> Jason.decode!()
        models = get_in(config, ["provider", "aiur", "models"])

        # The sentinel `_slot-1` is the ONLY model — no agent identifiers
        # are seeded at boot. Slot grows the map incrementally via the
        # identifier_miss rebuild path (U3).
        assert Map.keys(models) == ["issue-_slot-1"],
               "AE3: empty seed list must produce models = [issue-_slot-1] only, got #{inspect(Map.keys(models))}"
      after
        _ = File.rm_rf(workspace)
      end
    end
  end

  describe "AE4: slot materializes single-identifier models map after one select" do
    test "WorkspaceSetup.materialize_slot/5 with one identifier writes sentinel + that one" do
      workspace = Path.join(System.tmp_dir!(), "aiur-ae4-#{System.unique_integer([:positive])}")
      _ = File.rm_rf(workspace)

      try do
        {:ok, _token} =
          WorkspaceSetup.materialize_slot(workspace, "http://127.0.0.1:4097", ["13"], 1, 2)

        config = workspace |> Path.join("opencode.json") |> File.read!() |> Jason.decode!()
        models = get_in(config, ["provider", "aiur", "models"])

        assert Enum.sort(Map.keys(models)) == ["issue-13", "issue-_slot-1"],
               "AE4: one-identifier seed must produce sentinel + identifier, got #{inspect(Map.keys(models))}"
      after
        _ = File.rm_rf(workspace)
      end
    end
  end

  describe "AE5: slot models map accumulates incrementally" do
    test "two identifiers in materialize_slot produce both + sentinel" do
      workspace = Path.join(System.tmp_dir!(), "aiur-ae5-#{System.unique_integer([:positive])}")
      _ = File.rm_rf(workspace)

      try do
        {:ok, _token} =
          WorkspaceSetup.materialize_slot(
            workspace,
            "http://127.0.0.1:4097",
            ["13", "7"],
            1,
            3
          )

        config = workspace |> Path.join("opencode.json") |> File.read!() |> Jason.decode!()
        models = get_in(config, ["provider", "aiur", "models"])

        assert Enum.sort(Map.keys(models)) == ["issue-13", "issue-7", "issue-_slot-1"],
               "AE5: two-identifier seed must produce sentinel + both identifiers"

        # Crucially: no OTHER agent identifiers (e.g. `issue-12`, `issue-99`)
        # appear in the map. The slot's models map reflects ONLY what's
        # been explicitly attached, not the orchestrator's full agent list.
        for unexpected <- ["issue-12", "issue-99", "issue-foo"] do
          refute Map.has_key?(models, unexpected),
                 "AE5: unattached identifier #{inspect(unexpected)} must NOT appear in models map"
        end
      after
        _ = File.rm_rf(workspace)
      end
    end
  end

  describe "model name contract (R1)" do
    test "provider name stays `aiur` (provider grouping in opencode model picker)" do
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://x",
          bridge_token: "t",
          identifier: "_slot-1",
          opencode_os_pid: nil
        })

      assert get_in(config, ["provider", "aiur", "name"]) == "Aiur",
             "R1.2: provider name MAY stay `Aiur` (this is the human-facing provider grouping)"
    end
  end
end
