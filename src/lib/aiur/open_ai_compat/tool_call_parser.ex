defmodule Aiur.OpenAICompat.ToolCallParser do
  @moduledoc false

  @fence ~r/```(?:tool_call|json)\s*(\{.*?\})\s*```/s
  @tag ~r/<tool_call>\s*(\{.*?\})\s*<\/tool_call>/s

  @spec parse(String.t() | nil) :: [map()]
  def parse(text) when is_binary(text) do
    (captures(@tag, text) ++ captures(@fence, text))
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.flat_map(fn {json, index} -> decode(json, index) end)
  end

  def parse(_), do: []

  defp captures(regex, text), do: Regex.scan(regex, text, capture: :all_but_first) |> List.flatten()

  defp decode(json, index) do
    with {:ok, value} <- Jason.decode(json),
         name when is_binary(name) <- value["name"] || value["tool"],
         arguments when is_map(arguments) <- value["arguments"] do
      [%{id: value["id"] || "fallback-#{index + 1}", name: name, arguments: arguments}]
    else
      _ -> []
    end
  end
end
