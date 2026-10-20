defmodule Aiur.LandingWatch.QuarantineLifterTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.QuarantineLifter

  test "a merged fix ticket opens a PR removing its quarantine row" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    original = "# Quarantine list\nAiur.ExampleTest\tfixed flakes\t#900\nAiur.OtherTest\tstill flaky\t#901\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      response(method, url, original)
    end

    assert :ok =
             QuarantineLifter.lift(900,
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main",
               journal_path: journal
             )

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "#900"
    assert content =~ "#901"
    assert body["branch"] == "aiur/quarantine-lift-900-main"

    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", pr}
    assert pr["base"] == "main"
    assert pr["body"] =~ "#900"
  end

  test "a merged fix ticket also lifts its quarantined browser spec" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-browser-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    browser = "# Spec list\nBrowserSpec\tsrc/browser/tests/build-home-list.browser.spec.mjs\t#5118\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      browser_response(method, url, browser)
    end

    assert :ok = QuarantineLifter.lift(5118, request_fun: request, token: "test-gh-token", base_branch: "main", journal_path: journal)

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "build-home-list"
    assert body["branch"] == "aiur/quarantine-lift-5118-main-browser"
    refute_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", _}
  end

  test "a ticket closed without a merged fix PR has its entry lifted; an open ticket keeps its entry" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-closed-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    original = "# Quarantine list\nAiur.ExampleTest\tabandoned flake\t#900\nAiur.OtherTest\tstill flaky\t#901\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})

      case url do
        "https://api.github.com/repos/test-org/test-repo/issues/900" -> {:ok, %{status: 200, body: %{"state" => "closed"}}}
        "https://api.github.com/repos/test-org/test-repo/issues/901" -> {:ok, %{status: 200, body: %{"state" => "open"}}}
        _ -> response(method, url, original)
      end
    end

    assert :ok = QuarantineLifter.lift_closed(request_fun: request, token: "test-gh-token", base_branch: "main", journal_path: journal)

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "#900"
    assert content =~ "#901"
    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", pr}
    assert pr["body"] =~ "#900 now that the ticket is closed"
    refute_received {:request, :put, _, _}
  end

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=main", contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64(contents), "sha" => "list-blob", "encoding" => "base64"}}}

  # The browser list does not exist until a spec is first quarantined.
  defp response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt?ref=main", _contents),
    do: {:ok, %{status: 404, body: %{"message" => "Not Found"}}}

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/git/ref/heads/main", _contents),
    do: {:ok, %{status: 200, body: %{"object" => %{"sha" => "base-commit"}}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/refs", _contents),
    do: {:ok, %{status: 201, body: %{}}}

  defp response(:put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", _contents),
    do: {:ok, %{status: 200, body: %{}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/pulls", _contents),
    do: {:ok, %{status: 201, body: %{}}}

  defp response(method, url, _contents), do: flunk("unexpected GitHub request #{method} #{url}")

  defp browser_response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt?ref=main", contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64(contents), "sha" => "browser-blob", "encoding" => "base64"}}}

  defp browser_response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=main", _contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64("# Quarantine list\n"), "sha" => "list-blob", "encoding" => "base64"}}}

  defp browser_response(:put, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt", _contents),
    do: {:ok, %{status: 200, body: %{}}}

  defp browser_response(method, url, contents), do: response(method, url, contents)
end
