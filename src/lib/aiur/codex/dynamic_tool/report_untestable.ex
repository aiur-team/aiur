defmodule Aiur.Codex.DynamicTool.ReportUntestable do
  @moduledoc "Reports an acceptance criterion the agent cannot verify in its sandbox."

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.{Errors, Response}

  @impl true
  def tools, do: ["report_untestable"]

  @impl true
  def specs do
    [
      %{
        "name" => "report_untestable",
        "description" => "Report an acceptance criterion the agent cannot verify. This raises an operator alert and blocks terminal completion until operator sign-off.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["criterion", "reason"],
          "properties" => %{
            "criterion" => %{"type" => "string", "description" => "The exact acceptance criterion that remains unverified."},
            "reason" => %{"type" => "string", "description" => "Why the agent sandbox cannot verify it."}
          }
        }
      }
    ]
  end

  @impl true
  def execute("report_untestable", arguments, opts) do
    with {:ok, criterion} <- required_string(arguments, "criterion", :missing_untestable_criterion),
         {:ok, reason} <- required_string(arguments, "reason", :missing_untestable_reason),
         :ok <- call_reporter(Keyword.get(opts, :untestable_reporter), criterion, reason) do
      Response.build(true, Jason.encode!(%{"ok" => true, "criterion" => criterion, "reason" => reason}, pretty: true))
    else
      {:error, reason} -> Response.failure(Errors.payload(reason))
    end
  end

  defp call_reporter(reporter, criterion, reason) when is_function(reporter, 2), do: reporter.(criterion, reason)
  defp call_reporter(_reporter, _criterion, _reason), do: {:error, :untestable_reporter_unavailable}

  defp required_string(arguments, key, error) when is_map(arguments) do
    atom_key = if key == "criterion", do: :criterion, else: :reason

    case Map.get(arguments, key) || Map.get(arguments, atom_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error}
    end
  end

  defp required_string(_arguments, _key, error), do: {:error, error}
end
