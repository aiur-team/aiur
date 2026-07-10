defmodule Aiur.Codex.TurnEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.TurnEvents

  describe "metadata_from_message/2" do
    test "returns port metadata with usage merged when payload has usage" do
      port = open_cat_port()

      try do
        usage = %{"input_tokens" => 10, "output_tokens" => 5}
        meta = TurnEvents.metadata_from_message(port, %{"usage" => usage})
        assert meta[:usage] == usage
      after
        Port.close(port)
      end
    end

    test "returns port metadata with atom-key usage merged" do
      port = open_cat_port()

      try do
        usage = %{"input_tokens" => 3}
        meta = TurnEvents.metadata_from_message(port, %{usage: usage})
        assert meta[:usage] == usage
      after
        Port.close(port)
      end
    end

    test "ignores non-map usage field" do
      port = open_cat_port()

      try do
        meta = TurnEvents.metadata_from_message(port, %{"usage" => "not a map"})
        refute Map.has_key?(meta, :usage)
      after
        Port.close(port)
      end
    end

    test "returns port metadata unchanged when payload has no usage" do
      port = open_cat_port()

      try do
        meta = TurnEvents.metadata_from_message(port, %{"method" => "turn/completed"})
        refute Map.has_key?(meta, :usage)
      after
        Port.close(port)
      end
    end

    test "handles non-map payload" do
      port = open_cat_port()

      try do
        meta = TurnEvents.metadata_from_message(port, "raw string")
        assert is_map(meta)
      after
        Port.close(port)
      end
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end
end
