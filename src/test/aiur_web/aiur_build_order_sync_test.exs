defmodule AiurWeb.AiurBuildOrderSyncTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint AiurWeb.Endpoint

  # The dashboard serves the package's build output as ordinary static files, so a
  # page imports `/aiur-build-order/index.js` with no bundler. The copy is committed
  # (packages/aiur-build-order/dist is gitignored build output) and kept byte-equal
  # by scripts/sync-aiur-build-order.
  @copy Path.expand("../../priv/static/aiur-build-order", __DIR__)
  @dist Path.expand("../../../packages/aiur-build-order/dist", __DIR__)

  defp files(root) do
    root |> Path.join("*.js") |> Path.wildcard() |> Enum.concat(Path.wildcard(Path.join(root, "*.css")))
  end

  # Every way the copy differs from dist, in both directions.
  defp problems(copy, dist) do
    copied = files(copy) |> Enum.map(&Path.basename/1) |> Enum.sort()
    built = files(dist) |> Enum.map(&Path.basename/1) |> Enum.sort()

    Enum.map(built -- copied, &"#{&1} is missing from the copy") ++
      Enum.map(copied -- built, &"#{&1} is not in dist") ++
      for file <- copied, file in built, File.read!(Path.join(copy, file)) != File.read!(Path.join(dist, file)), do: "#{file} differs from dist"
  end

  defp get_authed(path) do
    authorization = "Basic " <> Base.encode64("operator:test-dashboard-secret")

    build_conn()
    |> Plug.Conn.put_req_header("authorization", authorization)
    |> get(path)
  end

  # dist/ is gitignored build output, so this only has something to compare after
  # `npm run build` in packages/aiur-build-order; its workflow builds it.
  @dist_complete File.dir?(@dist) and Path.wildcard(Path.join(@dist, "*.js")) != []
  @tag skip: if(@dist_complete, do: false, else: "packages/aiur-build-order/dist is missing or incomplete")
  test "the committed copy is byte-equal to packages/aiur-build-order/dist" do
    copied = files(@copy) |> Enum.map(&Path.basename/1)

    assert "index.js" in copied and "aiur-build-order.css" in copied
    problems = problems(@copy, @dist)
    assert problems == [], Enum.join(problems, "\n") <> "\nrun scripts/sync-aiur-build-order"
  end

  @tag :tmp_dir
  test "the sync check fails on files missing from either side or changed", %{tmp_dir: tmp_dir} do
    [copy, dist] = Enum.map(["copy", "dist"], &Path.join(tmp_dir, &1))

    for root <- [copy, dist], file <- ["index.js", "review.js"] do
      File.mkdir_p!(root)
      File.write!(Path.join(root, file), file)
    end

    File.write!(Path.join(dist, "notes.md"), "not synced")
    assert problems(copy, dist) == []

    File.rm!(Path.join(copy, "review.js"))
    assert problems(copy, dist) == ["review.js is missing from the copy"]

    File.write!(Path.join(copy, "stale.js"), "")
    File.write!(Path.join(copy, "index.js"), "edited")

    assert problems(copy, dist) == [
             "review.js is missing from the copy",
             "stale.js is not in dist",
             "index.js differs from dist"
           ]
  end

  test "the dashboard serves the package's entry module and stylesheet with revalidation" do
    entry = get_authed("/aiur-build-order/index.js")
    assert entry.status == 200
    assert Plug.Conn.get_resp_header(entry, "content-type") |> hd() =~ "javascript"
    assert Plug.Conn.get_resp_header(entry, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert entry.resp_body =~ "renderReview"

    stylesheet = get_authed("/aiur-build-order/aiur-build-order.css")
    assert stylesheet.status == 200
    assert Plug.Conn.get_resp_header(stylesheet, "content-type") |> hd() =~ "text/css"
    assert stylesheet.resp_body =~ "aiur-bo"
  end

  test "the package files require dashboard authentication" do
    assert get(build_conn(), "/aiur-build-order/index.js").status in [401, 403]
  end
end
