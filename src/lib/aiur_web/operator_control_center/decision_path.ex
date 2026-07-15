defmodule AiurWeb.OperatorControlCenter.DecisionPath do
  @moduledoc false

  @filters [:open, :blocking, :undelivered, :supervisor, :resolved, :superseded]

  @spec inbox(atom()) :: String.t()
  def inbox(filter), do: with_filter("/decisions", filter)

  @spec detail(String.t(), atom()) :: String.t()
  def detail(decision_id, filter) when is_binary(decision_id) do
    decision_id = URI.encode(decision_id, &URI.char_unreserved?/1)
    with_filter("/decisions/#{decision_id}", filter)
  end

  defp with_filter(path, filter) when filter in @filters do
    path <> "?" <> URI.encode_query(%{"filter" => Atom.to_string(filter)})
  end

  defp with_filter(path, _filter), do: path
end
