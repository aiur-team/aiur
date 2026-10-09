defmodule Aiur.JournalCompatibilityTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "regression guard: pre-rename journal replays identically without rewriting", %{tmp_dir: tmp_dir} do
    # Generated with the pre-rename append/2 implementation at da5859f65.
    fixture = Path.expand("../fixtures/journal/decisions.ndjson", __DIR__)
    path = Path.join(tmp_dir, "decisions.ndjson")
    File.cp!(fixture, path)

    assert {:ok,
            [
              %{"decision_id" => "dec_legacy", "event_id" => 1, "version" => 1},
              %{"decision_id" => "dec_legacy", "event_id" => 2, "version" => 2, "summary" => "Already durable"}
            ], nil} = Aiur.Journal.replay(path, &{:ok, &1})

    assert File.read!(path) == File.read!(fixture)
  end
end
