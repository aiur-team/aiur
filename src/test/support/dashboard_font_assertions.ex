defmodule Aiur.TestSupport.DashboardFontAssertions do
  @moduledoc false
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
    css = response(request.("/dashboard.css"), 200)
    families = Regex.scan(~r/font-family: '([^']+)'/, css, capture: :all_but_first)
    font_urls = Regex.scan(~r{url\('/aiur-style/fonts/([^']+)'\)}, css, capture: :all_but_first)

    # One face per family: the aiur-style variable faces replace the per-weight subsets.
    assert families == [["Bungee"], ["Space Grotesk"], ["JetBrains Mono"]]
    assert font_urls == [["Bungee-Regular.woff2"], ["SpaceGrotesk-Variable.woff2"], ["JetBrainsMono-Variable.woff2"]]
    refute css =~ "url(/fonts/"

    for [name] <- font_urls do
      conn = request.("/aiur-style/fonts/#{name}")
      assert binary_part(response(conn, 200), 0, 4) == "wOF2"
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["font/woff2"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    assert response(request.("/aiur-style/fonts/nope.woff2"), 404) != ""

    for path <- ["/aiur-style/fonts/..%2Ffonts.css", "/aiur-style/fonts/%2E%2E/fonts.css"] do
      assert_error_sent(400, fn -> request.(path) end)
    end

    assert response(request.("/fonts/space-grotesk-v22-latin.woff2"), 404) != ""
  end
end
