defmodule Aiur.Executor.TranscriptFormatTest do
  use ExUnit.Case, async: true
  alias Aiur.Executor.TranscriptFormat, as: Format

  test "census fixtures classify as ignored_known" do
    records = File.stream!("test/fixtures/claude_transcripts/2.1.29x/census.jsonl") |> Enum.map(&Jason.decode!/1)
    assert length(records) == 20
    assert Enum.map(records, &Format.classify/1) == List.duplicate(:ignored_known, 20)
  end

  test "conversation and attachment kinds distinguish supported and unknown records" do
    assert Format.classify(%{"type" => "assistant"}) == :mapped
    assert Format.classify(%{"type" => "user"}) == :mapped
    assert Format.classify(%{"type" => "attachment", "attachment" => %{"type" => "queued_command", "commandMode" => "prompt", "prompt" => "synthetic"}}) == :mapped
    for record <- [%{}, %{"type" => "new"}, %{"type" => "attachment", "attachment" => %{"type" => "new"}}], do: assert(Format.classify(record) == :unknown)
  end

  test "invalid versions never enter diagnostics and failed alert publication retries" do
    counts = Enum.reduce(1..200, Format.new(), fn _, counts -> Format.count(counts, %{"type" => "system", "version" => "PRIVATE"}) end)
    assert counts["untested_version"] == "invalid"
    Aiur.TestSupport.refute_leak(counts, "PRIVATE")
    binding = %{binding_id: "binding", generation: 1}
    assert Format.alert(counts, binding, fn _, _ -> {:error, :unavailable} end) == counts
    assert Format.alert(counts, binding, fn _, _ -> :ok end)["alerted"]
    assert Format.count(Format.new(), %{"version" => 42})["untested_version"] == "invalid"
  end

  test "tested version pin has exact boundaries and absence is separate" do
    for patch <- 287..299, do: assert(Format.version_status(%{"version" => "2.1.#{patch}"}) == :tested)
    for version <- ["2.1.286", "2.1.300", "2.1.299\n", "3.0.0", 291], do: assert(Format.version_status(%{"version" => version}) == :untested)
    assert Format.version_status(%{}) == :absent
    assert Format.version_status(%{"version" => nil}) == :absent
  end
end
