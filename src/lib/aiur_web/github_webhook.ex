defmodule AiurWeb.GithubWebhook do
  @moduledoc """
  Shared constants for the GitHub webhook receiver.

  The receiver spans three layers that must agree on the same request path: the
  endpoint's body reader (which caches raw bytes only for this path), the router
  route, and the verification plug. Keeping the path here means a rename cannot
  silently leave the body reader watching a stale path — which would fail closed
  and reject every delivery.
  """

  @path "/api/v1/github/webhook"
  @path_info String.split(@path, "/", trim: true)

  # GitHub refuses to deliver payloads larger than 25 MB, so anything above this
  # is not a delivery we could ever have signed. Scoping the cap to this reader
  # keeps the endpoint's default 8 MB parser limit intact for every other route.
  @max_body_bytes 25 * 1024 * 1024

  @raw_body_key :aiur_github_webhook_raw_body

  @doc "Request path the receiver is mounted at."
  @spec path() :: String.t()
  def path, do: @path

  @doc "Largest delivery body the receiver will buffer for verification."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "`Plug.Conn` private key holding the cached raw request body."
  @spec raw_body_key() :: atom()
  def raw_body_key, do: @raw_body_key

  @doc "True when `conn` targets the webhook receiver."
  @spec receiver_request?(Plug.Conn.t()) :: boolean()
  def receiver_request?(%Plug.Conn{path_info: @path_info}), do: true
  def receiver_request?(%Plug.Conn{}), do: false
end
