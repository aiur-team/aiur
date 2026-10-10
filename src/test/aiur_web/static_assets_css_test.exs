defmodule AiurWeb.StaticAssetsCssTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint AiurWeb.Endpoint

  @static_root Path.expand("../../priv/static", __DIR__)

  defp parts, do: @static_root |> Path.join("css/*.css") |> Path.wildcard() |> Enum.sort()

  defp embedded do
    {:ok, "text/css", css} = AiurWeb.StaticAssets.fetch("/dashboard.css")
    css
  end

  test "the embedded sheet is the partials in file-name order between fonts and palette" do
    assert length(parts()) > 1

    expected =
      Enum.join(
        [
          File.read!(Path.join(@static_root, "dashboard-fonts.css")),
          Enum.map_join(parts(), &File.read!/1),
          File.read!(Path.join(@static_root, "dashboard-palette.css"))
        ],
        "\n"
      )

    assert embedded() == expected
  end

  test "every partial has a unique order prefix, ends in a newline and stays within 500 lines" do
    prefixes = Enum.map(parts(), &(&1 |> Path.basename() |> String.slice(0, 3)))
    assert Enum.all?(prefixes, &(&1 =~ ~r/^\d\d-$/))
    assert prefixes == Enum.uniq(prefixes)

    for part <- parts() do
      body = File.read!(part)
      assert String.ends_with?(body, "\n"), "#{part} has no trailing newline"
      assert length(String.split(body, "\n")) - 1 <= 500, "#{part} is over 500 lines"
    end
  end

  test "the served /dashboard.css body is the embedded sheet" do
    authorization = "Basic " <> Base.encode64("operator:test-dashboard-secret")
    conn = build_conn() |> Plug.Conn.put_req_header("authorization", authorization) |> get("/dashboard.css")

    assert response(conn, 200) == embedded()
  end

  test "a partial added after compilation asks Mix to recompile" do
    refute AiurWeb.StaticAssets.__mix_recompile__?()

    extra = Path.join(@static_root, "css/99-recompile-probe-#{System.unique_integer([:positive])}.css")
    on_exit(fn -> File.rm(extra) end)
    File.write!(extra, "")

    assert AiurWeb.StaticAssets.__mix_recompile__?()
  end
end
