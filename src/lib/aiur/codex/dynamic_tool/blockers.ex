defmodule Aiur.Codex.DynamicTool.Blockers do
  @moduledoc """
  Dynamic tool handler for `aiur_declare_blocker` and `aiur_unblock`.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response

  @aiur_declare_blocker_description """
  Declare that another GitHub issue (by number) blocks the issue you
  are working on. Uses GitHub's native Issue Dependencies REST API.
  Cycle-checked client-side before submission. Returns `pending` once
  the ordered background operation is admitted; verify GitHub's
  authoritative dependency state before retrying an indeterminate call.
  An already-declared blocker remains idempotent.
  """
  @aiur_declare_blocker_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_number"],
    "properties" => %{
      "issue_number" => %{
        "type" => ["integer", "string"],
        "description" => "Issue number of the blocker (numeric, not the internal id)."
      }
    }
  }
  @aiur_unblock_description """
  Remove a previously-declared blocker from your current issue.
  """
  @aiur_unblock_input_schema @aiur_declare_blocker_input_schema

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["aiur_declare_blocker", "aiur_unblock"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "aiur_declare_blocker",
        "description" => @aiur_declare_blocker_description,
        "inputSchema" => @aiur_declare_blocker_input_schema
      },
      %{
        "name" => "aiur_unblock",
        "description" => @aiur_unblock_description,
        "inputSchema" => @aiur_unblock_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("aiur_declare_blocker", arguments, opts) do
    execute_dependency_action(arguments, opts, :declare)
  end

  def execute("aiur_unblock", arguments, opts) do
    execute_dependency_action(arguments, opts, :unblock)
  end

  @spec execute_dependency_action(term(), keyword(), :declare | :unblock) :: map()
  def execute_dependency_action(arguments, opts, action) do
    handler =
      case action do
        :declare -> Keyword.get(opts, :blocker_declarer)
        :unblock -> Keyword.get(opts, :unblocker)
      end

    error_atom =
      case action do
        :declare -> :blocker_declarer_unavailable
        :unblock -> :unblocker_unavailable
      end

    with {:ok, issue_number} <- normalize_issue_number(arguments),
         true <- is_function(handler, 1) || {:error, error_atom},
         {:ok, result} <- handler.(issue_number) do
      Response.build(
        true,
        Jason.encode!(
          %{"ok" => true, "issue_number" => issue_number, "result" => Response.jsonable(result)},
          pretty: true
        )
      )
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))

      false ->
        Response.failure(Errors.payload(error_atom))
    end
  end

  @spec normalize_issue_number(term()) :: {:ok, pos_integer()} | {:error, atom()}
  def normalize_issue_number(arguments) when is_map(arguments) do
    case Map.get(arguments, "issue_number") || Map.get(arguments, :issue_number) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, :invalid_issue_number}
        end

      _ ->
        {:error, :missing_issue_number}
    end
  end

  def normalize_issue_number(_), do: {:error, :invalid_issue_number}
end
