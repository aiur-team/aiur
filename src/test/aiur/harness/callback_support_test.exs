defmodule Aiur.Harness.CallbackSupportTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.Backend
  alias Aiur.Harness.Capabilities

  defmodule SteerAdapter do
    def steer(_session, _payload, _turn), do: {:ok, :steered}
  end

  defmodule QuestionAdapter do
    def reply_native_question(_session, _ref, _answers), do: :ok
    def release_native_question(_session, _ref, _text), do: :ok
  end

  defmodule PartialQuestionAdapter do
    def reply_native_question(_session, _ref, _answers), do: :ok
  end

  defmodule ReleaseOnlyAdapter do
    def release_native_question(_session, _ref, _text), do: :ok
  end

  defmodule WrongArityAdapter do
    def steer(_session, _payload), do: {:ok, :steered}
    def reply_native_question(_session, _answers), do: :ok
    def release_native_question(_session, _text), do: :ok
  end

  test "steer and native-question callbacks are reserved and optional" do
    for callback <- [steer: 3, reply_native_question: 3, release_native_question: 3] do
      assert callback in Backend.behaviour_info(:callbacks)
      assert callback in Backend.behaviour_info(:optional_callbacks)
    end
  end

  test "every registered adapter reports steer and native-question reply as none" do
    for key <- Aiur.CodingAgent.known_backends() do
      assert Capabilities.callback_support(key) == %{steer: :none, native_question_reply: :none}
    end
  end

  test "unknown backend returns a typed error" do
    assert Capabilities.callback_support("unknown-harness") == {:error, :unknown_backend}
  end

  test "steer support is independent of native questions" do
    assert Capabilities.callback_support_for_module(SteerAdapter) == %{
             steer: :native,
             native_question_reply: :none
           }
  end

  @tag :tmp_dir
  test "support loads an adapter from its beam before checking exports", %{tmp_dir: tmp_dir} do
    adapter = __MODULE__.ColdAdapter

    [{^adapter, beam}] =
      Code.compile_string("""
      defmodule #{inspect(adapter)} do
        def steer(_session, _payload, _turn), do: {:ok, :steered}
      end
      """)

    File.write!(Path.join(tmp_dir, "#{adapter}.beam"), beam)
    path = String.to_charlist(tmp_dir)
    true = :code.add_patha(path)

    on_exit(fn ->
      :code.purge(adapter)
      :code.delete(adapter)
      :code.del_path(path)
    end)

    :code.purge(adapter)
    true = :code.delete(adapter)
    assert :code.is_loaded(adapter) == false

    assert Capabilities.callback_support_for_module(adapter) == %{
             steer: :native,
             native_question_reply: :none
           }
  end

  test "native questions require both reply and release callbacks" do
    assert Capabilities.callback_support_for_module(QuestionAdapter) == %{
             steer: :none,
             native_question_reply: :native
           }

    assert Capabilities.callback_support_for_module(PartialQuestionAdapter) == %{
             steer: :none,
             native_question_reply: :none
           }

    assert Capabilities.callback_support_for_module(ReleaseOnlyAdapter) == %{
             steer: :none,
             native_question_reply: :none
           }
  end

  test "reserved callbacks with the wrong arity do not advertise support" do
    assert Capabilities.callback_support_for_module(WrongArityAdapter) == %{
             steer: :none,
             native_question_reply: :none
           }
  end
end
