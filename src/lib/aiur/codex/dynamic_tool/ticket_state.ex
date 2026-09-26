defmodule Aiur.Codex.DynamicTool.TicketState do
  @moduledoc """
  Dynamic tool handler for `aiur_set_ticket_state`.

  An agent used to advance its own ticket with a raw
  `gh issue edit N --remove-label agent:<old> --add-label agent:<new>`, naming
  the label it *believed* was current. That is unsafe under concurrency: the
  daemon owns state transitions too (the CI-pass handoff swaps `ci-wait` ->
  `in-progress`), so by the time the agent runs, the label it names may already
  be gone. When that happens the removal is a silent no-op and the ticket ends
  up carrying two `agent:*` state labels — a broken lifecycle state that denies
  dispatch and needs a heal (aiur-team/khala#198, #2805).

  An agent cannot fix this by naming a better label, because any label it names
  is a guess about the past. This tool removes the guess: the agent declares the
  state it wants to be in, and the daemon makes that label the ticket's *sole*
  `agent:*` state label — adding the new label first and then removing every
  other state label found on the freshly fetched issue body
  (`GitHub.IssueState.swap_labels/4`), the same writer the daemon uses for its
  own transitions.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response

  # States an agent may declare for its own ticket. `todo` is the pre-work state
  # dispatch owns, and `merging`/`cancelled` are Executor dispositions — an agent
  # claiming either would reverse an operator decision, so they are refused here
  # rather than silently written.
  @agent_settable_states ~w(in-progress ci-wait human-review rework error done)

  @description """
  Make `agent:<state>` the ONLY `agent:*` state label on the issue you are
  working on. Use this for every state transition instead of
  `gh issue edit --add-label` / `--remove-label`: Aiur re-reads the issue and
  removes every other state label it actually finds, so the transition is safe
  even when the daemon changed the label since you last looked. Naming the old
  label yourself is not safe — if the daemon already replaced it your removal is
  a no-op and the ticket is left carrying two state labels, which makes it
  undispatchable. Allowed states: #{Enum.join(@agent_settable_states, ", ")}.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "state" => %{
        "type" => "string",
        "description" =>
          "Target state, with or without the `agent:` prefix (e.g. `human-review` or `agent:human-review`). One of: " <>
            Enum.join(@agent_settable_states, ", ") <> "."
      }
    }
  }

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["aiur_set_ticket_state"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "aiur_set_ticket_state",
        "description" => @description,
        "inputSchema" => @input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("aiur_set_ticket_state", arguments, opts) do
    setter = Keyword.get(opts, :ticket_state_setter)

    with {:ok, state} <- normalize_state(arguments),
         true <- is_function(setter, 1) || {:error, :ticket_state_setter_unavailable},
         {:ok, result} <- setter.(state) do
      Response.build(
        true,
        Jason.encode!(
          %{"ok" => true, "state" => state, "result" => Response.jsonable(result)},
          pretty: true
        )
      )
    else
      {:error, reason} -> Response.failure(Errors.payload(reason))
      false -> Response.failure(Errors.payload(:ticket_state_setter_unavailable))
    end
  end

  @spec agent_settable_states() :: [String.t()]
  def agent_settable_states, do: @agent_settable_states

  @spec normalize_state(term()) :: {:ok, String.t()} | {:error, atom() | {atom(), term()}}
  def normalize_state(arguments) when is_map(arguments) do
    case Map.get(arguments, "state") || Map.get(arguments, :state) do
      state when is_binary(state) ->
        normalized =
          state
          |> String.trim()
          |> String.downcase()
          |> String.replace_prefix("agent:", "")
          |> String.trim()

        cond do
          normalized == "" -> {:error, :missing_ticket_state}
          normalized in @agent_settable_states -> {:ok, normalized}
          true -> {:error, {:unsettable_ticket_state, normalized}}
        end

      nil ->
        {:error, :missing_ticket_state}

      _other ->
        {:error, :invalid_ticket_state}
    end
  end

  def normalize_state(_arguments), do: {:error, :invalid_ticket_state}
end
