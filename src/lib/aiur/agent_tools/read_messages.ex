defmodule Aiur.AgentTools.ReadMessages do
  @moduledoc "Consuming reads of the calling agent's held async messages."
  @behaviour Aiur.AgentTools.Handler
  alias Aiur.AgentTools.Response

  @impl true
  def tools, do: ["aiur_read_messages"]

  @impl true
  def specs do
    [
      %{
        "name" => "aiur_read_messages",
        "description" => "Read and acknowledge your held async operator messages, oldest first. No client cursor; repeat calls consume the next batch.",
        "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{"max" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 50}}}
      }
    ]
  end

  @impl true
  def execute("aiur_read_messages", arguments, opts) do
    with {:ok, max} <- validate(arguments),
         reader when is_function(reader, 1) <- Keyword.get(opts, :message_reader),
         {:ok, result} <- reader.(max) do
      Response.build(true, Response.encode_payload(result))
    else
      {:error, :invalid_arguments} -> Response.failure(%{error: "Expected only max, an integer from 1 to 50", retryable: false})
      {:error, reason} -> unavailable(reason)
      nil -> unavailable(:reader_unavailable)
    end
  catch
    :exit, reason -> unavailable(reason)
  end

  defp validate(args) when is_map(args) do
    max = Map.get(args, "max", 50)
    if Map.keys(args) -- ["max"] == [] and is_integer(max) and max in 1..50, do: {:ok, max}, else: {:error, :invalid_arguments}
  end

  defp validate(_args), do: {:error, :invalid_arguments}
  defp unavailable(reason), do: Response.failure(%{error: inspect(reason), retryable: true})
end
