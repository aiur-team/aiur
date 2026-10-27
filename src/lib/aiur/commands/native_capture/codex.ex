defmodule Aiur.Commands.NativeCapture.Codex do
  @moduledoc "Gated translation of native user-input requests into held Commands."

  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.NativeCapture
  alias Aiur.Config

  @spec handle(port() | pid(), term(), map(), map()) :: :unhandled | :approved | :input_required | {:held, String.t(), map()} | {:error, :port_closed}
  def handle(port, id, params, ctx) do
    if Config.decisions_native_capture?(:codex) do
      capture(port, id, params, ctx)
    else
      :unhandled
    end
  end

  @doc "Reply to a held JSON-RPC user-input request with all structured answers."
  @spec reply(port() | pid(), term(), map()) :: :ok | {:error, :port_closed}
  defdelegate reply(port, request_id, answers), to: UserInputAnswers

  defp capture(port, id, params, ctx) do
    with {:ok, answers} <- UserInputAnswers.unavailable_answers(params),
         thread when is_binary(thread) <- Map.get(ctx, :tool_call_thread_id),
         turn when is_binary(turn) <- Map.get(ctx, :turn_id) do
      ref = "codex:#{thread}:#{turn}:#{id}"

      normalized = %{
        harness: :codex,
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
