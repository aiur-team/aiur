defmodule Aiur.Events.CommentFilter do
  @moduledoc false

  @spec agent_workpad?(term()) :: boolean()
  def agent_workpad?(%{} = comment) do
    comment
    |> comment_body()
    |> String.trim_leading()
    |> String.starts_with?("## Agent Workpad")
  end

  def agent_workpad?(_comment), do: false

  defp comment_body(comment) do
    Map.get(comment, "body") || Map.get(comment, :body) || ""
  end
end
