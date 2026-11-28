defmodule Aiur.AgentTools.NoChange do
  @moduledoc "Worker handoff for a verified fix already present on the integration branch."

  @behaviour Aiur.AgentTools.Handler

  alias Aiur.AgentTools.{Errors, Response}

  @description """
  Finish this ticket when you verified its requested fix is already present on the current integration branch and made no change.
  """

  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["commit", "command", "output"],
    "properties" => %{
      "commit" => %{"type" => "string", "description" => "Full commit SHA on the current integration branch containing the fix."},
      "command" => %{"type" => "string", "description" => "Command used to verify the fix, including relevant arguments."},
      "output" => %{"type" => "string", "description" => "Relevant output showing the fix is present and working."}
    }
  }

  @impl true
  def tools, do: ["aiur_finish_no_change"]

  @impl true
  def specs do
    [%{"name" => "aiur_finish_no_change", "description" => @description, "inputSchema" => @input_schema}]
  end

  @impl true
  def execute("aiur_finish_no_change", arguments, opts) do
    with {:ok, evidence} <- evidence(arguments),
         writer when is_function(writer, 2) <- Keyword.get(opts, :no_change_finisher),
         {:ok, result} <- writer.(evidence, opts) do
      Response.build(true, Jason.encode!(Response.jsonable(result), pretty: true))
    else
      {:error, reason} -> Response.failure(Errors.payload({:no_change, reason}))
      _ -> Response.failure(Errors.payload({:no_change, :unavailable}))
    end
  end

  defp evidence(arguments) when is_map(arguments) do
    fields = for key <- ["commit", "command", "output"], do: {key, value(arguments, key)}

    case Enum.find(fields, fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end) do
      nil ->
        evidence = Map.new(fields, fn {key, value} -> {key, String.trim(value)} end)

        if Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, evidence["commit"]) do
          {:ok, evidence}
        else
          {:error, :invalid_commit}
        end

      {key, _} ->
        {:error, {:missing, key}}
    end
  end

  defp evidence(_), do: {:error, :invalid_arguments}
  defp value(arguments, key), do: Map.get(arguments, key)
end
