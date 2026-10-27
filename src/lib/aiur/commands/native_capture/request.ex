defmodule Aiur.Commands.NativeCapture.Request do
  @moduledoc false
  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.NativeCapture

  @spec capture(port() | pid(), term(), map(), map(), :codex | :claude) :: term()
  def capture(port, id, params, ctx, harness) do
    with {:ok, answers} <- UserInputAnswers.unavailable_answers(params),
         thread when is_binary(thread) <- Map.get(ctx, :tool_call_thread_id),
         turn when is_binary(turn) <- Map.get(ctx, :turn_id) do
      ref = "#{harness}:#{thread}:#{turn}:#{id}"

      normalized = %{
        harness: harness,
        hold: if(harness == :claude, do: :deferred, else: :in_band),
        native_ref: ref,
        call_id: Map.get(params, "itemId"),
        turn_id: turn,
        blocking: Map.get(params, "isBlocking", true),
        questions: Enum.map(params["questions"], &question/1)
      }

      case NativeCapture.capture(normalized, ctx) do
        {:policy, :approval} ->
          :unhandled

        {:release, text} ->
          release(port, id, answers, text, ctx)

        {:command, decision} ->
          {:held, ref,
           %{
             native_ref: ref,
             decision_id: decision.decision_id,
             since: DateTime.utc_now(),
             request_id: id,
             question_ids: decision.native.question_ids,
             thread_id: thread,
             turn_id: turn
           }}
      end
    else
      :error -> :input_required
      _missing_identity -> :unhandled
    end
  end

  defp question(raw) do
    %{
      question_id: raw["id"],
      header: raw["header"],
      question: raw["question"],
      options: options(raw["options"]),
      multi_select: Map.get(raw, "multiSelect", false),
      allow_other: Map.get(raw, "isOther", true),
      secret: Map.get(raw, "isSecret", false)
    }
  end

  defp options(options) when is_list(options) do
    Enum.map(options, fn
      option when is_map(option) -> %{label: option["label"], description: option["description"]}
      _invalid -> %{}
    end)
  end

  defp options(_invalid), do: []

  defp release(port, id, answers, text, ctx) do
    answers = Map.new(answers, fn {question_id, _answer} -> {question_id, %{"answers" => [text]}} end)

    with :ok <- ctx.send_response.(port, %{"id" => id, "result" => %{"answers" => answers}}) do
      :approved
    end
  end
end
