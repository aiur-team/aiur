defmodule AiurWeb.Build.PayloadTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.{Payload, Read}
  @dir Path.expand("../../fixtures/build_home", __DIR__)

  test "fixtures reach the full strict schema (future fixture guard)" do
    for name <- ~w(live dense newrepo noqueue offline) do
      {:ok, data} = FixtureSource.full(dataset: name)
      assert Payload.validate(Payload.snapshot(data, "epoch", 0)) == :ok
    end

    hostile = @dir |> Path.join("hostile.json") |> File.read!() |> Jason.decode!()
    assert Payload.validate(hostile["snapshot"]) == :ok
  end

  for {name, path, value, expected} <- [
        {"pct is numeric", ["sections", "now", 0, "pct"], "50", "sections.now.0.pct"},
        {"effort is an enum", ["sections", "now", 0, "agent", "effort"], "<b>", "sections.now.0.agent.effort"},
        {"hue is numeric", ["epics", "bugs", "hue"], "1);x", "epics.bugs.hue"},
        {"cue is plan-only", ["sections", "nq", 0, "cue"], %{}, "sections.nq.0.cue"},
        {"section is an enum", ["sections", "now", 0, "sec"], "x", "sections.now.0.sec"},
        {"history requires dated end", ["sections", "hist", 0, "end"], nil, "sections.hist.0.end"},
        {"wave is positive", ["sections", "plan", 0, "wave"], 0, "sections.plan.0.wave"},
        {"order has epic references", ["order", 0], "missing", "order.0"},
        {"unknown row keys fail", ["sections", "now", 0, "colour"], "red", "sections.now.0.colour"}
      ] do
    test "validator: #{name}" do
      path = Enum.map(unquote(Macro.escape(path)), fn key -> if is_integer(key), do: Access.at(key), else: key end)
      data = put_in(fixture(), path, unquote(Macro.escape(value)))
      data = if unquote(name) == "section is an enum", do: Payload.diff(%{now: data["now"], upsert: [hd(data["sections"]["now"])], remove: [], set: %{}}, "E", 1, nil), else: data
      assert {:error, errors} = Payload.validate(data)
      assert Enum.any?(errors, fn {path, _reason} -> path == if(unquote(name) == "section is an enum", do: "upsert.0.sec", else: unquote(expected)) end)
    end
  end

  test "counts must cover order" do
    data = fixture() |> update_in(["counts"], &Map.delete(&1, "bugs"))
    assert {:error, errors} = Payload.validate(data)
    assert {"counts.bugs", :missing} in errors
  end

  test "every source must be present" do
    data = fixture() |> update_in(["sources"], &Map.delete(&1, "queue"))
    assert {:error, errors} = Payload.validate(data)
    assert {"sources.queue", :missing} in errors
  end

  test "locked usage cannot carry values" do
    data = Map.put(fixture(), "usage", Map.put(Read.locked_usage(), "providers", []))
    assert {:error, errors} = Payload.validate(data)
    assert {"usage.providers", :unknown} in errors
  end

  test "row fetches missing values rather than defaulting" do
    row = fixture()["sections"]["now"] |> hd() |> Map.delete("pct")
    assert Payload.row(row) == {:error, {:missing, "pct"}}
    assert Payload.row(Map.new(row, fn {k, v} -> {String.to_existing_atom(k), v} end)) == {:error, {:missing, :pct}}
  end

  test "unknown stays null and raw strings stay raw" do
    data = fixture() |> put_in(["sections", "now", Access.at(0), "pct"], nil) |> Map.put("counts", nil)
    data = data |> put_in(["sections", "now", Access.at(0), "est"], nil) |> put_in(["sections", "now", Access.at(0), "start"], nil)
    data = put_in(data, ["sections", "now", Access.at(0), "title"], "A & B")
    json = Payload.snapshot(data, "E", 1) |> Jason.encode!() |> Jason.decode!()
    assert Payload.validate(json) == :ok
    assert json["counts"] == nil
    row = hd(json["sections"]["now"])
    assert Map.take(row, ~w(pct est start title)) == %{"pct" => nil, "est" => nil, "start" => nil, "title" => "A & B"}
  end

  test "scrub replaces invalid UTF-8 without joining valid characters" do
    hostile = @dir |> Path.join("hostile.json") |> File.read!() |> Jason.decode!()
    data = put_in(hostile["snapshot"], ["sections", "now", Access.at(0), "title"], Base.decode64!(hostile["invalid_title_base64"]))
    encoded = Payload.snapshot(data, "E", 0) |> Jason.encode!() |> Jason.decode!()
    assert hd(encoded["sections"]["now"])["title"] == "A�B"
  end

  test "window filter drops older history and merges socket-specific metadata" do
    data = fixture()
    [older, newer | _] = data["sections"]["hist"] |> Enum.sort_by(& &1["end"])
    history = %{data["history"] | "from" => newer["end"]}
    message = Payload.diff(%{now: data["now"], upsert: [older, newer], remove: [], set: %{history_meta: %{total: 999, undated: 1}}}, "E", 2, history)
    assert message["upsert"] == [newer]
    assert message["set"] == %{"history" => %{history | "total" => 999, "undated" => 1}}
    assert Payload.validate(message) == :ok
  end

  test "source index generation never reaches the wire" do
    message = fixture() |> Map.put("index_generation", 6) |> Payload.snapshot("E", 0)
    refute Map.has_key?(message, "index_generation")
  end

  test "future regression guard: window budgets and full-index mean row size" do
    {bytes, rows} =
      Enum.reduce(~w(live dense newrepo noqueue offline), {0, 0}, fn name, {bytes, rows} ->
        {:ok, data} = FixtureSource.full(dataset: name)
        all = data["sections"] |> Map.values() |> List.flatten()
        {bytes + Enum.sum(Enum.map(all, &Payload.bytes/1)), rows + length(all)}
      end)

    IO.puts("build payload census mean_row_bytes=#{Float.round(bytes / rows, 2)} rows=#{rows}")
    assert bytes / rows <= 400

    for name <- ~w(live dense) do
      {:ok, data} = FixtureSource.snapshot(dataset: name)
      budgeted = put_in(data, ["sections", "nq"], [])
      bytes = Payload.bytes(Payload.snapshot(budgeted, "fixture", 0))
      IO.puts("build snapshot dataset=#{name} bytes_without_nq=#{bytes} full_window_bytes=#{Payload.bytes(data)}")
      assert bytes <= 65_536
    end
  end

  defp fixture do
    {:ok, data} = FixtureSource.full(dataset: "live")
    data
  end
end
