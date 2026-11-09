defmodule Aiur.Harness.NativeQuestionUnavailableTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Config
  alias Aiur.Harness.Capabilities

  test "unreadable capture configuration reports unknown support and reason" do
    previous = Application.fetch_env(:aiur, :backend_catalog)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :backend_catalog, value)
        :error -> Application.delete_env(:aiur, :backend_catalog)
      end
    end)

    Application.put_env(:aiur, :backend_catalog, nil)
    assert Config.settings() == {:error, :backend_catalog_unavailable}

    assert {:ok, %{native_question: :unknown, native_question_reason: :unknown}} =
             Capabilities.delivery_primitives("codex")
  end
end
