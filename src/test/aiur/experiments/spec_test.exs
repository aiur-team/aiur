defmodule Aiur.Experiments.SpecTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Spec
  @fixtures Path.join(__DIR__, "fixtures")

  defp line do
    %{
      "title" => "Delivery speed",
      "design" => %{"kind" => "before_after", "change" => %{"type" => "release", "ref" => "v0.0.9", "time" => "2026-10-09T00:00:00Z"}},
      "metrics" => [%{"ref" => "delivery-speed/start_to_merge"}]
    }
  end

  test "fills configured windows and metrics defaults" do
    assert {:ok, spec} = Spec.new(line(), default_min_samples: 21, default_before_days: 7)
    assert spec.min_samples == 21
    assert spec.windows == %{"before" => %{"start" => "2026-10-02T00:00:00Z", "end" => "2026-10-09T00:00:00Z"}, "after" => %{"start" => "2026-10-09T00:00:00Z", "end" => nil}}
    assert spec.metrics == [%{"ref" => "delivery-speed/start_to_merge", "direction" => "decrease", "primary" => true}]
    assert spec.stratify_by == ["complexity"]
  end

  test "full v1 spec round trips unchanged through JSON" do
    fixture = Jason.decode!(File.read!(Path.join(@fixtures, "valid_line.json")))["spec"]
    assert {:ok, spec} = Spec.new(fixture)
    assert spec |> Jason.encode!() |> Jason.decode!() == fixture
    refute Map.has_key?(Spec.to_map(%{spec | existing: true}), "existing")
  end

  test "manual change without time returns its field error" do
    attrs = put_in(line(), ["design", "change"], %{"type" => "manual", "ref" => "smoke"})
    assert {:error, errors} = Spec.new(attrs)
    assert Enum.any?(errors, &(&1.path == "design.change.time"))
  end

  test "tag resolves time using injected resolver and identifies unresolved ref" do
    attrs = put_in(line(), ["design", "change"], %{"type" => "tag", "ref" => "v0.0.9"})
    assert {:ok, spec} = Spec.new(attrs, resolve_time: fn "v0.0.9" -> {:ok, "2026-10-09T00:00:00Z"} end)
    assert spec.design["change"]["time"] == "2026-10-09T00:00:00Z"
    assert {:error, errors} = Spec.new(attrs, resolve_time: fn _ -> {:error, :missing} end)
    assert Enum.any?(errors, &(&1.path == "design.change.time" and String.contains?(&1.message, "v0.0.9")))
  end

  test "A/B requires multiple cohorts and an existing control" do
    valid = Jason.decode!(File.read!(Path.join(@fixtures, "valid_ab.json")))["spec"]
    assert {:ok, _} = Spec.new(valid)
    attrs = valid |> put_in(["design", "cohorts"], Enum.take(valid["design"]["cohorts"], 1)) |> put_in(["design", "control"], "missing")
    assert {:error, errors} = Spec.new(attrs)
    assert Enum.any?(errors, &(&1.path == "design.cohorts"))
    assert Enum.any?(errors, &(&1.path == "design.control"))
  end

  test "returns all independent validation errors at once" do
    assert {:error, errors} = Spec.new(line() |> Map.put("title", "") |> Map.put("min_samples", 0) |> Map.put("metrics", []))
    assert MapSet.new(Enum.map(errors, & &1.path)) == MapSet.new(~w(title min_samples metrics))
  end

  test "rejects backwards windows" do
    attrs = Map.put(line(), "windows", %{"before" => %{"start" => "2026-10-10T00:00:00Z", "end" => "2026-10-09T00:00:00Z"}, "after" => %{"start" => "2026-10-09T00:00:00Z", "end" => nil}})
    assert {:error, errors} = Spec.new(attrs)
    assert Enum.any?(errors, &(&1.path == "windows.before.end"))
  end

  for path <- Path.wildcard(Path.join(@fixtures, "*.json")) do
    @path path
    test "published JSON Schema agrees with validator: #{Path.basename(path)}" do
      fixture = Jason.decode!(File.read!(@path))
      schema = Path.expand("../../../priv/experiments/spec.v1.schema.json", __DIR__) |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
      assert match?({:ok, %Spec{}}, Spec.new(fixture["spec"])) == fixture["valid"]
      assert ExJsonSchema.Validator.validate(schema, fixture["spec"]) == :ok == fixture["valid"]
    end
  end
end
