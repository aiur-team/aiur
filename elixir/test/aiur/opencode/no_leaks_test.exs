defmodule Aiur.Opencode.NoLeaksTest do
  @moduledoc """
  Regression: the strings `_warm` and `_placeholder` MUST never appear
  in any user-visible field of opencode model display config
  (`Protocol.opencode_json/1`) regardless of the identifier used to
  bootstrap it. Origin: 2026-05-21 brainstorm R6.
  """

  use ExUnit.Case, async: true

  alias Aiur.Opencode.Protocol

  @leaky_substrings ["_warm", "_placeholder", "Aiur _warm", "Aiur _placeholder"]

  describe "opencode_json/1" do
    test "model display name does not contain identifier-derived markers" do
      # Even when the identifier itself is `_warm`, the model display
      # `name` field MUST be clean. The model `id` keeps `issue-_warm`
      # for the bridge's routing, but human-visible chrome is identifier-free.
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://127.0.0.1:4097",
          bridge_token: "secret",
          identifier: "_warm",
          opencode_os_pid: nil
        })

      model_entry =
        get_in(config, ["provider", "aiur", "models", "issue-_warm"])

      assert is_map(model_entry)

      for leak <- @leaky_substrings do
        refute Map.get(model_entry, "name") == leak,
               "model display name leaked #{inspect(leak)}: #{inspect(model_entry)}"
      end

      # Affirmative: it should always be the clean "Aiur" string.
      assert Map.get(model_entry, "name") == "Aiur"
    end

    test "agent identifier never bleeds into model display name" do
      config =
        Protocol.opencode_json(%{
          bridge_url: "http://127.0.0.1:4097",
          bridge_token: "secret",
          identifier: "issue-42",
          opencode_os_pid: nil
        })

      assert get_in(config, ["provider", "aiur", "models", "issue-issue-42", "name"]) == "Aiur"
    end
  end
end
