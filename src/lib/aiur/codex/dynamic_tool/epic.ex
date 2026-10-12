defmodule Aiur.Codex.DynamicTool.Epic do
  @moduledoc "Daemon-bound epic assignment tool; agents cannot supply provenance."
  @behaviour Aiur.Codex.DynamicTool.Handler
  alias Aiur.Codex.DynamicTool.{Errors, Response}

  @impl true
  def tools, do: ["aiur_set_epic"]
  @impl true
  def specs do
    [
      %{
        "name" => "aiur_set_epic",
        "description" => "Put tickets into a general epic (or clear it). Records you as the actor. Use for categorising tickets; batch up to 200 ids.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "epic" => %{"type" => "string"},
            "ids" => %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1, "maximum" => 9_999_999_999}, "minItems" => 1, "maxItems" => 200},
            "clear" => %{"type" => "boolean"},
            "backfill" => %{"type" => "boolean"}
          }
        }
      }
    ]
  end

  @impl true
  def execute("aiur_set_epic", arguments, opts) do
    with {:ok, normalized} <- normalize(arguments), setter when is_function(setter, 1) <- opts[:epic_setter], {:ok, result} <- setter.(normalized) do
      Response.build(true, Jason.encode!(%{ok: true, result: Response.jsonable(result)}))
    else
      {:error, reason} -> Response.failure(Errors.payload(reason))
      _ -> Response.failure(Errors.payload(:epic_setter_unavailable))
    end
  end

  @spec normalize(term()) :: {:ok, map()} | {:error, atom()}
  def normalize(args) when is_map(args) do
    clear = Map.get(args, "clear", false)
    backfill = Map.get(args, "backfill", false)
    epic = args["epic"]
    valid = Enum.all?(Map.keys(args), &(&1 in ~w(epic ids clear backfill))) and is_boolean(clear) and is_boolean(backfill)
    valid = valid and if(clear, do: not Map.has_key?(args, "epic") and not backfill, else: is_binary(epic) and epic != "")
    if valid and valid_ids?(args), do: {:ok, %{clear: clear, backfill: backfill, epic: epic, ids: args["ids"]}}, else: {:error, :invalid_epic_arguments}
  end

  def normalize(_args), do: {:error, :invalid_epic_arguments}

  defp valid_ids?(%{"ids" => ids}) do
    is_list(ids) and length(ids) in 1..200 and Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_999_999_999))
  end

  defp valid_ids?(_args), do: true
end
