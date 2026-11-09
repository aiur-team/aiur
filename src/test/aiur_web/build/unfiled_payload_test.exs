defmodule AiurWeb.Build.UnfiledPayloadTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Payload

  test "pack identities and filing aliases survive the wire" do
    row = row()
    assert Payload.validate(Payload.ticket(row, "e", 0)) == :ok
    assert Payload.validate(Payload.ticket(%{row | "id" => "9", "num" => 9, "src" => nil, "was" => row["id"]}, "e", 0)) == :ok
  end

  test "pack source is required exactly on pack rows" do
    row = row()
    assert_error(%{row | "src" => nil}, "row.src")
    assert_error(%{row | "id" => "9", "num" => 9}, "row.src")
    assert_error(%{row | "qpos" => 1}, "row.id")
  end

  test "pack paths and waves reject private paths and negative waves" do
    row = row()
    for path <- ["/home/private/pack.json", "~/pack.json"], do: assert_error(put_in(row, ["src", "path"], path), "row.src.path")
    assert_error(put_in(row, ["src", "wave"], -1), "row.src.wave")
  end

  test "pack ids and aliases reject malformed identities" do
    row = row()

    for id <- ["pack:../x", "pack:demo", "pack:demo/a/b", "pack:demo/A\n"] do
      assert_error(%{row | "id" => id}, "row.id")
      assert_error(%{row | "id" => "9", "num" => 9, "src" => nil, "was" => id}, "row.was")
    end
  end

  test "packs health cannot disappear from a snapshot" do
    {:ok, data} = FixtureSource.full(dataset: "live")
    data = update_in(data, ["sources"], &Map.delete(&1, "packs"))
    assert {:error, errors} = Payload.validate(data)
    assert {"sources.packs", :missing} in errors
  end

  defp row do
    {:ok, data} = FixtureSource.full(dataset: "live")

    Map.merge(hd(data["sections"]["plan"]), %{
      "id" => "pack:platform-program-2026-10/CLI-LOGIN-T01",
      "num" => nil,
      "qpos" => nil,
      "src" => %{"kind" => "pack", "path" => "builds/demo/build-order.json", "wave" => 0},
      "was" => nil
    })
  end

  defp assert_error(row, path) do
    assert {:error, errors} = Payload.validate(Payload.ticket(row, "e", 0))
    assert Enum.any?(errors, fn {field, _} -> field == path end), inspect(errors)
  end
end
