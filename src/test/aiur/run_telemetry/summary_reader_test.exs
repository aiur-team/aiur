defmodule Aiur.RunTelemetry.SummaryReaderTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.SummaryReader

  test "streams duplicate resource envelopes and bounds actor samples while retaining full profiles" do
    samples = for i <- 0..9999, do: %{"availability" => "measured", "timestamp_ms" => i, "actor" => "ticket:7", "cpu_percent" => i}
    records = for i <- 0..9999, do: %{"kind" => "resource", "boot_id" => "boot", "sequence" => i}
    lifecycle = %{"kind" => "lifecycle", "attributes" => %{"event" => "dispatch"}}
    profile = %{"cpu_percent" => %{"count" => 10_000, "mean" => 4999.5, "max" => 9999}}
    path = write!(Jason.encode!(%{"records" => [lifecycle | records], "actors" => %{"ticket:7" => %{"samples" => samples, "profile" => profile}}}))

    assert {:ok, decoded} = SummaryReader.read(path)
    assert [^lifecycle, %{"kind" => "resource", "sequence" => 0}] = decoded["records"]
    actor = decoded["actors"]["ticket:7"]
    assert length(actor["samples"]) <= 180
    assert hd(actor["samples"])["timestamp_ms"] == 0
    assert List.last(actor["samples"])["timestamp_ms"] == 9999
    assert actor["profile"] == profile
    assert :erlang.external_size(decoded) < 50_000
  end

  test "rejects truncated, trailing, and oversized tokens rather than allocating without a bound" do
    for body <- ["{\"a\":", "{} false", "{\"a\":\"" <> String.duplicate("x", 2_000_000) <> "\"}"] do
      assert {:error, :invalid_summary} = SummaryReader.read(write!(body))
    end

    assert {:error, :missing} = SummaryReader.read(Path.join(System.tmp_dir!(), "missing-#{make_ref() |> inspect()}"))
  end

  test "rejects cumulative retained data and deep nesting even when individual tokens are small" do
    large = Jason.encode!(%{values: List.duplicate(String.duplicate("x", 256_000), 100)})
    deep = Enum.reduce(1..20, "0", fn _, body -> "[" <> body <> "]" end)
    for body <- [large, deep], do: assert({:error, :invalid_summary} = SummaryReader.read(write!(body)))
  end

  test "future regression guard: preserves JSON null and escaped strings across chunk boundaries" do
    text = String.duplicate("a", 65_520) <> "\"\\λ"
    assert {:ok, %{"text" => ^text, "unknown" => nil}} = SummaryReader.read(write!(Jason.encode!(%{text: text, unknown: nil})))
  end

  defp write!(body) do
    path = Path.join(System.tmp_dir!(), "summary-reader-#{System.unique_integer([:positive])}.json")
    File.write!(path, body)
    on_exit(fn -> File.rm!(path) end)
    path
  end
end
