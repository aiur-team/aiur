defmodule Aiur.TestSupport.DashboardFontAssertions do
  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [response: 2, assert_error_sent: 2]

  def assert_bootstrap(html) do
    assert html =~ ~s(data-palette="gruvbox")
    assert {restore_at, _} = :binary.match(html, ~s|getItem("aiur-palette")|)
    assert {stylesheet_at, _} = :binary.match(html, "/dashboard.css")
    assert restore_at < stylesheet_at
    assert html =~ "/dashboard.css"
    assert html =~ "/build-home/loader.js"
  end

  def assert_fonts(request) do
    font_urls = Regex.scan(~r{url\(/fonts/([^)]+)\)}, response(request.("/dashboard.css"), 200))
    assert length(font_urls) == 39

    for [_full, name] <- Enum.uniq(font_urls) do
      conn = request.("/fonts/#{name}")
      assert binary_part(response(conn, 200), 0, 4) == "wOF2"
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["font/woff2"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=31536000"]
    end

    assert response(request.("/fonts/nope.woff2"), 404) != ""

    for path <- ["/fonts/..%2Fdashboard.css", "/fonts/%2E%2E/dashboard.css"] do
      assert_error_sent(400, fn -> request.(path) end)
    end

    assert AiurWeb.StaticAssets.served_path?(["fonts", "space-grotesk-v22-latin.woff2"])
  end
end
