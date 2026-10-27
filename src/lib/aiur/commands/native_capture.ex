defmodule Aiur.Commands.NativeCapture do
  @moduledoc """
  Records normalized native questions as Commands, without holding or replying to a harness.

  The caller supplies trusted `ctx.ticket`, `ctx.source` and optionally
  `ctx.session_ref`, `ctx.provenance`, `ctx.workspace` and `ctx.store`.
  Native input uses atom keys and never supplies trusted request identity.
  """

  require Logger

  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.RequestContent
  alias Aiur.DecisionStore
  alias Aiur.Signal

  @spec classify(map()) :: :approval | :secret | :question
  def classify(normalized) do
    questions = Map.get(normalized, :questions, [])

    # Secrets take precedence even when a question also offers an approval label.
    cond do
      Enum.any?(questions, &(Map.get(&1, :secret) == true)) -> :secret
      approval?(questions) -> :approval
      true -> :question
    end
  end

  defp approval?(questions) do
    reshaped =
      Enum.map(questions, fn question ->
        %{
          "id" => Map.get(question, :question_id),
          "options" => Enum.map(Map.get(question, :options, []), &%{"label" => Map.get(&1, :label)})
        }
      end)

    match?({:ok, _, _}, UserInputAnswers.approval_answers(%{"questions" => reshaped}))
  end

  @spec to_request(map(), map()) :: {:ok, map(), keyword()} | {:error, term()}
  def to_request(normalized, ctx) do
    with {:ok, questions} <- RequestContent.normalize_questions(Map.get(normalized, :questions)),
         ref when is_binary(ref) and byte_size(ref) > 0 <- Map.get(normalized, :native_ref) do
      [first | rest] = questions
      first = %{first | options: Enum.with_index(first.options, 1) |> Enum.map(fn {option, index} -> %{option | id: "o#{index}"} end)}
      questions = [first | rest]

      payload = %{
        source_id: "native:" <> ref,
        question: question_text(questions),
        options: first.options,
        context: %{short_summary: first.header},
        blocking: Map.get(normalized, :blocking, true),
        kind: "native_question"
      }

      native =
        normalized
        |> Map.take([:harness, :native_ref, :call_id, :turn_id])
        |> Map.merge(%{hold: :in_band, question_ids: Enum.map(questions, & &1.question_id)})

      opts = [
        ticket: Map.fetch!(ctx, :ticket),
        source: Map.get(ctx, :source, %{}),
        provenance: Map.get(ctx, :provenance),
        requester: %{
          kind: :worker,
          ticket: ctx.ticket.identifier,
          session_ref: Map.get(ctx, :session_ref),
          harness: to_string(normalized.harness)
        },
        origin: :native_question,
        native: native,
        questions: questions
      ]

      {:ok, payload, opts}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_native_ref}
    end
  end

  defp question_text([question]), do: question.question
  defp question_text(questions), do: "#{length(questions)} questions: " <> Enum.map_join(questions, ", ", &(&1.header || &1.question_id))

  @spec capture(map(), map()) :: {:command, Aiur.Decision.t()} | {:release, String.t()} | {:policy, :approval}
  def capture(normalized, ctx) do
    case classify(normalized) do
      :approval -> {:policy, :approval}
      :secret -> release_secret(ctx)
      :question -> record(normalized, ctx)
    end
  end

  defp record(normalized, ctx) do
    with {:ok, payload, opts} <- to_request(normalized, ctx),
         {:ok, %{decision: decision}} <- request(payload, opts, Map.get(ctx, :store, DecisionStore)) do
      {:command, decision}
    else
      {:error, _reason} ->
        Logger.warning("native_capture phase=request_failed ticket=#{ctx.ticket.identifier}; releasing native question")
        {:release, UserInputAnswers.non_interactive_answer()}
    end
  end

  defp request(payload, opts, store) do
    DecisionStore.request(payload, opts, store)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp release_secret(ctx) do
    case Signal.agent_alert("ticket.#{ctx.ticket.identifier}.agent.native-secret-question", secret_release_text(),
           needs_attention: true,
           issue: ctx.ticket.identifier,
           workspace: Map.get(ctx, :workspace)
         ) do
      :ok -> :ok
      {:error, _reason} -> Logger.warning("native_capture phase=secret_alert_failed ticket=#{ctx.ticket.identifier}")
    end

    {:release, secret_release_text()}
  end

  @spec release_text(String.t()) :: String.t()
  def release_text(decision_id), do: "Your question is recorded as Command #{decision_id}. Stop and end your turn; the answer will arrive as a message."

  @spec secret_release_text() :: String.t()
  def secret_release_text, do: "aiur cannot collect secrets through Commands."
end
