defmodule AiurWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook deliveries that have already been proven authentic by
  `AiurWeb.GithubWebhook.Auth`.

  GitHub abandons a delivery after 10 seconds and retries it, so this action
  acknowledges immediately and does no work. Consuming deliveries — normalizing
  them onto `Aiur.Events.GithubFirehose` — is a separate change (W-3 of #1675);
  until then a verified delivery is acknowledged and dropped.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn

  @accepted_body ~s({"status":"accepted"})

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(202, @accepted_body)
  end
end
