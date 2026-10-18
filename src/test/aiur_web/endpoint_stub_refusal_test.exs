defmodule AiurWeb.EndpointStubRefusalTest do
  # Briefly puts a stub in the global endpoint env, so not async.
  use ExUnit.Case, async: false

  test "starting the test endpoint refuses stubs left in the global env (#4908)" do
    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
    on_exit(fn -> Application.put_env(:aiur, AiurWeb.Endpoint, previous) end)
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(previous || [], :open_tickets_fun, fn -> [] end))

    assert_raise RuntimeError, ~r/open_tickets_fun/, &Aiur.TestSupport.start_owned_endpoint!/0
  end
end
