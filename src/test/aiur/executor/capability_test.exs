defmodule Aiur.Executor.CapabilityTest do
  use ExUnit.Case, async: true

  alias Aiur.Executor.Capability

  @now ~U[2026-11-20 12:00:00Z]

  test "no binding is unknown and never claims a harness or tested range" do
    assert Capability.capability(nil, @now) == %{
             harness: nil,
             cli_version: nil,
             status: :unknown,
             reason: :awaiting_first_hook,
             tested_range: nil,
             observed_at: "2026-11-20T12:00:00Z"
           }
  end

  for {name, snapshot, ingest, status, reason} <- [
        {"detached binding", %{state: "detached", harness: "claude"}, %{}, :unknown, :not_attached},
        {"awaiting hook", %{state: "awaiting_first_hook", harness: "claude"}, %{}, :unknown, :awaiting_first_hook},
        {"Codex untested version", %{state: "attached", harness: "codex", codex_cli_version: "0.172.0"}, %{codex_rollout: :untested}, :untested, :version_untested},
        {"Codex unsupported reader", %{state: "attached", harness: "codex"}, %{codex_rollout: :unsupported}, :unsupported, :codex_reader_unavailable},
        {"Codex tested reader", %{state: "attached", harness: "codex", codex_cli_version: "0.171.2"}, %{codex_rollout: :tested}, :proven, nil},
        {"Claude format drift", %{state: "attached", harness: "claude", transcript_format: %{"alerted" => true}}, %{}, :untested, :format_drift},
        {"Claude observed transcript", %{state: "attached", harness: "claude", transcript_format: %{"versions" => %{"tested" => 1}, "tested_version" => "2.1.299"}}, %{}, :proven, nil},
        {"unknown harness", %{state: "attached", harness: "other"}, %{}, :unknown, :awaiting_first_hook}
      ] do
    test "#{name} maps to #{status}/#{inspect(reason)}" do
      record = Capability.capability(unquote(Macro.escape(snapshot)), @now, unquote(Macro.escape(ingest)))
      assert record.status == unquote(status)
      assert record.reason == unquote(reason)

      assert record.cli_version == Map.get(unquote(Macro.escape(snapshot)), :codex_cli_version) || Map.get(get_in(unquote(Macro.escape(snapshot)), [:transcript_format]) || %{}, "untested_version") ||
               Map.get(get_in(unquote(Macro.escape(snapshot)), [:transcript_format]) || %{}, "tested_version")

      assert record.observed_at == "2026-11-20T12:00:00Z"
    end
  end

  test "attached snapshot without tested transcript evidence remains unknown" do
    record = Capability.capability(%{state: "attached", harness: "claude"}, @now, %{})
    assert record.status == :unknown
    assert record.reason == :awaiting_first_hook
  end

  test "identity mapping preserves internal detail with closed reasons" do
    assert Capability.identity_entry(%{status: :untested, reason: :version_untested}) == %{state: :degraded, reason: :unknown, detail: "version_untested"}
    assert Capability.identity_entry(%{status: :unsupported, reason: :layout_unknown}) == %{state: :unavailable, reason: :unknown, detail: "layout_unknown"}
  end
end
