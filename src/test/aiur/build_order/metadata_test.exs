defmodule Aiur.BuildOrder.MetadataTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Marker, Metadata}

  test "parses exactly one valid label from each planning dimension" do
    metadata = Metadata.parse(["phase:4", "complexity:3", "build-lane:runtime"])

    assert %{complexity: 3, phase: 4, lane: "runtime", warnings: []} = metadata
  end

  test "keeps missing, duplicate, and malformed labels explicit" do
    missing = Metadata.parse([])
    duplicate = Metadata.parse(["complexity:1", "complexity:3", "phase:2", "build-lane:runtime"])
    malformed = Metadata.parse(["complexity:9", "phase:0", "build-lane:invented"])

    assert %{complexity: :unknown, phase: :unphased, lane: :unassigned} = missing
    assert %{complexity: :unknown, phase: 2, lane: "runtime"} = duplicate
    assert %{complexity: :unknown, phase: :unphased, lane: :unassigned} = malformed

    assert Enum.map(missing.warnings, & &1.code) == [
             :missing_complexity,
             :missing_phase,
             :missing_lane
           ]

    assert :ambiguous_complexity in Enum.map(duplicate.warnings, & &1.code)

    assert Enum.map(malformed.warnings, & &1.code) == [
             :invalid_complexity,
             :invalid_phase,
             :invalid_lane
           ]
  end

  test "is total for bounded arbitrary planning labels" do
    labels = [
      nil,
      42,
      <<255>>,
      "phase:" <> String.duplicate("9", 30),
      "build-lane:" <> String.duplicate("x", 300)
    ]

    assert %Metadata{complexity: :unknown, phase: :unphased, lane: :unassigned} =
             Metadata.parse(labels)
  end

  test "parses the bounded optional logical marker without making it structural" do
    body =
      "<!-- aiur-planning-issue\n{\"schema\":2,\"logical_id\":\"BO-001\",\"plan_version\":1,\"approved_planning_commit\":\"4d8de9508206e08e314f2730cd916501a3b4cafd\"}\n-->"

    assert :absent = Marker.parse("no marker")
    assert {:ok, %{logical_id: "BO-001", plan_version: 1}} = Marker.parse(body)

    assert {:warning, %{code: :invalid_marker}} =
             Marker.parse("<!-- aiur-planning-issue {bad} -->")
  end

  test "keeps malformed, duplicate, and oversized markers as bounded warnings" do
    marker =
      "<!-- aiur-planning-issue\n{\"schema\":2,\"logical_id\":\"BO-001\",\"plan_version\":1,\"approved_planning_commit\":\"4d8de9508206e08e314f2730cd916501a3b4cafd\"}\n-->"

    assert {:warning, %{code: :ambiguous_marker}} = Marker.parse(marker <> marker)
    assert {:warning, %{code: :invalid_marker}} = Marker.parse(<<255>>)
    assert {:warning, %{code: :invalid_marker}} = Marker.parse(String.duplicate("x", 32_769))
  end
end
