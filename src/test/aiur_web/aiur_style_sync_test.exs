defmodule AiurWeb.AiurStyleSyncTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint AiurWeb.Endpoint

  @copy Path.expand("../../priv/static/aiur-style", __DIR__)
  @dist Path.expand("../../../packages/aiur-style/dist", __DIR__)

  files = fn root -> root |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.map(&Path.relative_to(&1, root)) end
  @copied files.(@copy)

  defp get_authed(path) do
    authorization = "Basic " <> Base.encode64("operator:test-dashboard-secret")
    build_conn() |> Plug.Conn.put_req_header("authorization", authorization) |> get(path)
  end

  # dist/ is gitignored build output, so this only has something to compare
  # after a full `npm run build` in packages/aiur-style; the aiur-style workflow builds it.
  # A partial dist (CI builds some of it) skips instead of failing on a missing file.
  @dist_complete File.dir?(@dist) and Enum.all?(@copied, &File.regular?(Path.join(@dist, &1)))
  @tag skip: if(@dist_complete, do: false, else: "packages/aiur-style/dist is missing or incomplete")
  test "the committed copy is byte-equal to packages/aiur-style/dist" do
    copied = @copied
    assert "tokens.css" in copied and "fonts.css" in copied and "init/theme-init.js" in copied

    for file <- copied do
      assert File.read!(Path.join(@copy, file)) == File.read!(Path.join(@dist, file)),
             "#{file} differs from dist; run scripts/sync-aiur-style"
    end
  end

  test "the layout loads tokens before dashboard.css, which carries the fonts, and replaces the inline theme script" do
    html = "/" |> get_authed() |> html_response(200)
    order = Enum.map(["/aiur-style/tokens.css", "/dashboard.css"], &:binary.match(html, &1))
    assert Enum.all?(order, &(&1 != :nomatch))
    assert order == Enum.sort(order)
    refute html =~ "/aiur-style/fonts.css"
    assert html =~ ~s(<script src="/aiur-style/init/theme-init.js" data-default="dark">)
    refute html =~ "dataset.theme = theme"
  end

  test "aiur-style files are served, fonts immutably and the rest revalidating" do
    tokens = get_authed("/aiur-style/tokens.css")
    assert tokens.status == 200
    assert Plug.Conn.get_resp_header(tokens, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert get_authed("/aiur-style/js/theme.js").status == 200
    assert get_authed("/aiur-style/init/theme-init.js").status == 200

    font = get_authed("/aiur-style/fonts/SpaceGrotesk-Variable.woff2")
    assert font.status == 200
    assert Plug.Conn.get_resp_header(font, "cache-control") == ["public, max-age=31536000, immutable"]

    bungee_url = "/aiur-style/fonts/Bungee-Regular.woff2"
    assert "/dashboard.css" |> get_authed() |> response(200) =~ bungee_url
    bungee = get_authed(bungee_url)
    assert bungee.status == 200
    assert Plug.Conn.get_resp_header(bungee, "cache-control") == ["public, max-age=31536000, immutable"]
    assert binary_part(bungee.resp_body, 0, 4) == "wOF2"
  end

  test "aiur-style files require dashboard authentication" do
    assert get(build_conn(), "/aiur-style/tokens.css").status in [401, 403]
  end
end
