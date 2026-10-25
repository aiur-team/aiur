defmodule Aiur.DecisionAnswerComment do
  @moduledoc false

  alias Aiur.{Decision, DecisionAnswer, Tracker}

  @doc "Idempotently mirrors an accepted answer to the ticket's durable comment history."
  @spec ensure(Decision.t(), keyword()) :: :ok | {:error, term()}
  def ensure(decision, opts \\ [])

  def ensure(%Decision{answer: %DecisionAnswer{} = answer} = decision, opts) do
    ensure_comment(decision, answer, opts)
  rescue
    error -> {:error, {:publisher_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:publisher_crashed, {kind, reason}}}
  end

  def ensure(_decision, _opts), do: {:error, :answer_missing}

  defp ensure_comment(decision, answer, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_classified_issue_comments/1)
    create = Keyword.get(opts, :create, &Tracker.create_comment/2)

    :global.trans({{__MODULE__, answer.action_id}, self()}, fn ->
      marker = marker(answer.action_id)

      with {:ok, comments} <- fetch.(decision.ticket.identifier),
           false <- Enum.any?(comments, &(comment_body(&1) =~ marker)) do
        create.(decision.ticket.identifier, render(decision, marker))
      else
        true -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec marker(String.t()) :: String.t()
  def marker(action_id), do: "<!-- aiur-decision-answer:#{action_id} -->"

  @doc false
  @spec render(Decision.t(), String.t() | nil) :: String.t()
  def render(decision, marker \\ nil)

  def render(%Decision{} = decision, marker) do
    answer = decision.answer
    marker = marker || marker(answer.action_id)

    chosen =
      if answer.selected_option_id do
        option = Enum.find(decision.options, &(&1.id == answer.selected_option_id))
        "#{answer.selected_option_id}: #{if(option, do: option.label, else: answer.selected_option_id)}"
      else
        answer.custom_response
      end

    """
    ## Answered decision

    #{marker}

    **Question:** #{decision.question}

    **Answer:** #{chosen}

    **Answered by:** #{answer.actor.kind}#{if answer.actor.id, do: " (#{answer.actor.id})", else: ""}

    **Answered at:** #{DateTime.to_iso8601(answer.accepted_at)}
    """
    |> String.trim()
  end

  defp comment_body(comment) when is_map(comment), do: Map.get(comment, :body, Map.get(comment, "body", ""))
  defp comment_body(_comment), do: ""
end
