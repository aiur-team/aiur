defmodule Aiur.Opencode.NoLeaksTest do
  @moduledoc """
  Regression coverage for the model display name in
  `Protocol.opencode_json/1`. Two contracts:

  1. Model display name MUST equal the model key (the identifier). This
     is what makes opencode's chat chrome read `aiur · issue-13` instead
     of `Aiur · Aiur`. Origin: 2026-05-21 R1 (pane-attach-queue plan).
  2. The string `Aiur` (the legacy hardcoded display name) MUST NOT
     appear as the value of any model `name` field. Catches a regression
     where a literal `"Aiur"` is reintroduced anywhere in the models map.
  """

  use ExUnit.Case, async: true

  alias Aiur.Opencode.Protocol

  describe "opencode_json/1" do
    test "model display name equals the model key (identifier)" do
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://127.0.0.1:4097",
          bridge_token: "secret",
          identifier: "_slot-1",
          opencode_os_pid: nil,
          extra_identifiers: ["issue-13", "issue-7"]
        })

      models = get_in(config, ["provider", "aiur", "models"])

      for {key, %{"name" => name}} <- models do
        assert key == name,
               "model key #{inspect(key)} should have name=#{inspect(key)} but had name=#{inspect(name)}"
      end
    end

    test "literal `Aiur` never appears as a model display name" do
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://127.0.0.1:4097",
          bridge_token: "secret",
          identifier: "issue-42",
          opencode_os_pid: nil
        })

      names =
        config
        |> get_in(["provider", "aiur", "models"])
        |> Map.values()
        |> Enum.map(& &1["name"])

      refute "Aiur" in names, "regression: hardcoded `Aiur` model name reintroduced: #{inspect(names)}"
    end
  end
end
