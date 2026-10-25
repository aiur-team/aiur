defmodule Aiur.Handoff.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Aiur.Handoff.{Compatibility, Fallback}

  test "a departed relay under a long state path falls back without a socket argument exit" do
    agent = %{"transport" => %{"kind" => "relay", "protocol" => 1, "directory" => Path.join(System.tmp_dir!(), String.duplicate("missing", 30))}}
    assert {:error, :relay_gone} = Compatibility.check(agent, %{}, config_fingerprint: "same")
    assert {:error, :relay_socket_missing} = Fallback.stop(agent)
  end
end
