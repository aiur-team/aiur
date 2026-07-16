defmodule AiurWeb.OperatorControlCenter.UnitsURL do
  @moduledoc """
  Versioned, canonical query state for the renderer-independent Units policy.
  """

  alias AiurWeb.OperatorControlCenter.UnitsPolicy

  @version "1"

  @spec version() :: String.t()
  def version, do: @version

  @spec default_selection() :: UnitsPolicy.selection()
  def default_selection, do: UnitsPolicy.default_selection()

  @doc "The named reset used when a valid selection yields zero rows."
  @spec zero_result_reset() :: UnitsPolicy.selection()
  def zero_result_reset, do: default_selection()

  @spec encode(UnitsPolicy.selection() | term()) :: String.t()
  def encode(selection), do: selection |> params() |> URI.encode_query()

  @spec params(UnitsPolicy.selection() | term()) :: [{String.t(), String.t()}]
  def params(selection) do
    selection = UnitsPolicy.normalize_selection(selection)
    scope = UnitsPolicy.scope(selection)

    [{"v", @version}]
    |> maybe_put_scope(scope)
    |> maybe_put_conditions(selection)
  end

  @spec decode(String.t() | map() | term()) :: UnitsPolicy.selection()
  def decode(query) when is_binary(query) do
    query
    |> decode_query()
    |> decode()
  end

  def decode(params) when is_map(params) do
    if valid_version?(Map.get(params, "v") || Map.get(params, :v)) do
      UnitsPolicy.normalize_selection(%{
        scope: Map.get(params, "scope") || Map.get(params, :scope),
        conditions: Map.get(params, "conditions") || Map.get(params, :conditions)
      })
    else
      default_selection()
    end
  end

  def decode(_query), do: default_selection()

  defp maybe_put_scope(params, :live), do: params
  defp maybe_put_scope(params, scope), do: params ++ [{"scope", Atom.to_string(scope)}]

  defp maybe_put_conditions(params, selection) do
    selected =
      UnitsPolicy.conditions()
      |> Enum.filter(&UnitsPolicy.selected?(selection, &1))
      |> Enum.map_join(",", &Atom.to_string/1)

    if selected == "", do: params, else: params ++ [{"conditions", selected}]
  end

  defp valid_version?(nil), do: true
  defp valid_version?(@version), do: true
  defp valid_version?(_version), do: false

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    _error -> %{}
  end
end
