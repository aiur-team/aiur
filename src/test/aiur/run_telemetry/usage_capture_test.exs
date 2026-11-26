defmodule Aiur.RunTelemetry.UsageCaptureTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.UsageCapture
  alias Aiur.TrackerIdentity

  @identity %TrackerIdentity{
    status: :joinable,
    kind: :github,
    owner: "o",
    repository: "r",
    provider_id: "node-1",
    identifier: "42",
    reason: nil
  }

  setup do
    name = :"usage_capture_#{System.unique_integer([:positive])}"
    start_supervised!({UsageCapture, name: name})
    {:ok, opts: [name: name, recorder: fn :lifecycle, attributes, _opts -> send(self(), {:recorded, attributes}) end]}
  end

  test "records the aggregate totals once, and again only when they change", %{opts: opts} do
    totals = %{tokens: %{input: 120_000, output: 30_000, cached_input: 5}, money: %{{:provider_reported, "USD"} => Decimal.new("1.50")}}
    query = fn %{tickets: [@identity]} -> summary(totals) end

    UsageCapture.run("42", @identity, [query: query] ++ opts)
    UsageCapture.run("42", @identity, [query: query] ++ opts)

    assert_received {:recorded, attributes}
    assert %{event: "ticket_usage", input_tokens: 120_000, output_tokens: 30_000, cached_tokens: 5} = attributes
    assert %{cost_amount: "1.50", cost_currency: "USD", coverage: "complete"} = attributes
    refute_received {:recorded, _duplicate}

    changed = put_in(totals.tokens.input, 130_000)
    UsageCapture.run("42", @identity, [query: fn _ -> summary(changed) end] ++ opts)
    assert_received {:recorded, %{input_tokens: 130_000}}
  end

  test "an unavailable aggregate records coverage unavailable and no numbers", %{opts: opts} do
    UsageCapture.run("42", @identity, [query: fn _ -> exit(:noproc) end] ++ opts)

    assert_received {:recorded, attributes}
    assert attributes.coverage == "unavailable"
    refute Map.has_key?(attributes, :input_tokens)
  end

  test "an unjoinable identity records coverage unavailable without querying", %{opts: opts} do
    UsageCapture.run("42", TrackerIdentity.unjoinable(:legacy), [query: fn _ -> flunk("queried") end] ++ opts)

    assert_received {:recorded, %{coverage: "unavailable"}}
  end

  defp summary(totals) do
    %{
      totals: totals,
      health: :healthy,
      coverage: %{selected_cells: 3, unknown_attribution: %{ticket: 0, run_id: 0}, projection: %{partial_records: 0}}
    }
  end
end
