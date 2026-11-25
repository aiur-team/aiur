defmodule AiurWeb.OperatorNotifyControllerTest do
  # `POST /api/v1/operator/notify` is how a host app or script reaches the
  # operator's devices without a shell on the daemon host.
  use Aiur.TestSupport

  import Phoenix.ConnTest, only: [json_response: 2]
  import Plug.Test, only: [conn: 3]

  alias AiurWeb.OperatorNotifyController

  test "a valid notification is published and answered with its event id" do
    :ok = Aiur.Events.subscribe("operator.notify.live")

    conn = notify(%{"kind" => "live", "text" => "#645 is live", "ticket" => "645"})

    assert %{"id" => id, "topic" => "operator.notify.live"} = json_response(conn, 202)
    assert is_integer(id) and id > 0
    assert_receive {:event, %{topic: "operator.notify.live", body: "#645 is live", ticket: "645"}}, 1_000
  end

  test "an unknown kind or missing text is refused with a typed error and nothing is published" do
    :ok = Aiur.Events.subscribe("operator.notify.info")

    assert %{"error" => %{"code" => "unknown_kind"}} =
             %{"kind" => "urgent", "text" => "x"} |> notify() |> json_response(422)

    assert %{"error" => %{"code" => "missing_fields"}} =
             %{"kind" => "info"} |> notify() |> json_response(422)

    refute_receive {:event, %{topic: "operator.notify.info"}}, 200
  end

  defp notify(params), do: :post |> conn("/api/v1/operator/notify", params) |> OperatorNotifyController.call(:create)
end
