defmodule Aiur.LandingWatch.QuarantinePRTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.QuarantinePR

  test "creates one list-entry commit and opens a PR with the issue and both run links" do
    parent = self()

    observations = [
      %{pr: 41, run_url: "https://github.com/test-org/test-repo/actions/runs/101"},
      %{pr: 42, run_url: "https://github.com/test-org/test-repo/actions/runs/202"}
    ]

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      response(method, url)
    end

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: "Aiur.ExampleTest :: fails repeatedly", observations: observations},
               900,
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main",
               quarantine_list_fun: fn -> {:ok, "# Existing entries\n"} end
             )

    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/git/blobs", %{"content" => contents}}
    assert contents =~ "Aiur.ExampleTest\tfails repeatedly\t#900"

    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", body}
    assert body["base"] == "main"
    assert body["body"] =~ "Refs #900"
    assert body["body"] =~ Enum.at(observations, 0).run_url
    assert body["body"] =~ Enum.at(observations, 1).run_url
  end

  test "does not create another PR for a test already in the quarantine list" do
    list = "Aiur.ExampleTest\tfails repeatedly\t#900\n"

    assert {:ok, :already_quarantined} =
             QuarantinePR.open(
               %{identity: "Aiur.ExampleTest :: fails repeatedly", observations: []},
               900,
               request_fun: fn _ -> flunk("already listed test must not make a GitHub request") end,
               token: "test-gh-token",
               quarantine_list_fun: fn -> {:ok, list} end
             )
  end

  test "decodes GitHub content with line-wrapped base64" do
    parent = self()
    contents = "# " <> String.duplicate("quarantine list content ", 5) <> "\n"
    encoded = Base.encode64(contents)
    <<first::binary-size(60), rest::binary>> = encoded
    wrapped = first <> "\n" <> rest

    request = fn
      %{method: :get, url: "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=main"} ->
        {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => wrapped}}}

      %{method: method, url: url} = call ->
        send(parent, {:request, method, url, Map.get(call, :body)})
        response(method, url)
    end

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: "Aiur.ExampleTest :: fails repeatedly", observations: []},
               900,
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main"
             )

    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/git/blobs", %{"content" => updated}}
    assert updated == String.trim_trailing(contents) <> "\nAiur.ExampleTest\tfails repeatedly\t#900\n"
  end

  defp response(:get, "https://api.github.com/repos/test-org/test-repo"),
    do: {:ok, %{status: 200, body: %{"default_branch" => "main", "html_url" => "https://github.com/test-org/test-repo"}}}

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/git/ref/heads/main"),
    do: {:ok, %{status: 200, body: %{"object" => %{"sha" => "base-commit"}}}}

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/git/commits/base-commit"),
    do: {:ok, %{status: 200, body: %{"tree" => %{"sha" => "base-tree"}}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/refs"),
    do: {:ok, %{status: 201, body: %{"object" => %{"sha" => "base-commit"}}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/blobs"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-blob"}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/trees"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-tree"}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/commits"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-commit"}}}

  defp response(:patch, "https://api.github.com/repos/test-org/test-repo/git/refs/heads/" <> _branch),
    do: {:ok, %{status: 200, body: %{}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/pulls"),
    do: {:ok, %{status: 201, body: %{"number" => 901}}}

  defp response(method, url), do: flunk("unexpected GitHub request #{method} #{url}")
end
