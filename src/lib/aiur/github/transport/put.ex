defmodule Aiur.GitHub.Transport.Put do
  @moduledoc false

  def request(%{url: url, token: token, body: body} = req, quota_request, github_headers, request_options) do
    quota_request.(req, fn ->
      options = github_headers.(token, req) |> request_options.(req) |> Keyword.put(:json, body)
      Req.put(url, options)
    end)
  end
end
