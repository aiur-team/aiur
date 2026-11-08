defmodule AiurPushRelay.LogFilterTest do
  use ExUnit.Case, async: true

  test "logger filter removes secret metadata while preserving safe measurements" do
    event = %{
      level: :info,
      msg: {:string, "delivery"},
      meta: %{
        sealed: "ciphertext",
        push_token: "token",
        send_secret: "secret",
        handle: "h_safe",
        size: 20,
        status: :delivered
      }
    }

    assert AiurPushRelay.LogFilter.filter(event, nil).meta == %{
             handle: "h_safe",
             size: 20,
             status: :delivered
           }
  end
end
