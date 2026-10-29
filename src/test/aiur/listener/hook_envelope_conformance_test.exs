defmodule Aiur.Listener.HookEnvelopeConformanceTest do
  use ExUnit.Case, async: true
  alias Aiur.Listener.HookEnvelope
  alias Aiur.Listener.HookFrame
  @goldens Path.expand("../../../priv/listener_spec/v1/goldens", __DIR__)

  for path <- Path.wildcard(Path.join(@goldens, "hook/*.json")) do
    @golden Jason.decode!(File.read!(path))
    test "hook golden #{Path.basename(path)}" do
      golden = @golden
      result = HookEnvelope.envelope(golden["harness"], get_in(golden, ["parsed", "event"]), golden["frame"], stop_context: golden["stop_context"])

      stdout =
        case result do
          {:ok, output} -> output
          :none -> ""
        end

      assert stdout == golden["stdout"]
    end
  end

  for path <- Path.wildcard(Path.join(@goldens, "frame/*.json")) do
    @golden Jason.decode!(File.read!(path))
    test "frame golden #{Path.basename(path)}" do
      golden = @golden
      template = golden["template"]
      wrap = fn lines -> template["open"] <> Enum.join(lines, template["separator"]) <> template["close"] end
      entries = Enum.map(golden["entries"], &%{prefix: "", body: &1["body"], suffix: ""})
      result = HookFrame.render(entries, wrap, suffix: golden["suffix"], budget: golden["budget"] || 65_536)

      cond do
        golden["error"] -> assert result == {:error, :frame_metadata_too_large}
        golden["frame"] == nil -> assert result == :none
        true -> assert result == {:ok, golden["frame"], golden["consumed"]}
      end
    end
  end

  test "future regression guard: fixture discovery covers all vendored hook and frame cases" do
    assert length(Path.wildcard(Path.join(@goldens, "hook/*.json"))) == 50
    assert length(Path.wildcard(Path.join(@goldens, "frame/*.json"))) == 7
  end
end
