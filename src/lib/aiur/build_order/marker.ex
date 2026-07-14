defmodule Aiur.BuildOrder.Marker do
  @moduledoc "Parser for the bounded optional Build Order planning marker."

  alias Aiur.BuildOrder.Diagnostic

  @max_body_bytes 32_768
  @max_marker_bytes 1_024
  @marker ~r/<!--\s*aiur-planning-issue\s*(.*?)\s*-->/s

  @type t :: %__MODULE__{
          schema: 2,
          logical_id: String.t(),
          plan_version: pos_integer(),
          approved_planning_commit: String.t()
        }

  defstruct [:schema, :logical_id, :plan_version, :approved_planning_commit]

  @spec parse(term()) :: :absent | {:ok, t()} | {:warning, Diagnostic.t()}
  def parse(body) when is_binary(body) and byte_size(body) <= @max_body_bytes do
    if String.valid?(body),
      do: parse_marker(body),
      else: {:warning, Diagnostic.new(:invalid_marker)}
  end

  def parse(_body), do: {:warning, Diagnostic.new(:invalid_marker)}

  defp parse_marker(body) do
    case Regex.scan(@marker, body, capture: :all_but_first) do
      [] -> :absent
      [[marker]] -> decode(marker)
      _ -> {:warning, Diagnostic.new(:ambiguous_marker)}
    end
  end

  defp decode(marker) when byte_size(marker) <= @max_marker_bytes do
    with {:ok, value} <- Jason.decode(marker),
         {:ok, parsed} <- validate(value) do
      {:ok, parsed}
    else
      _ -> {:warning, Diagnostic.new(:invalid_marker)}
    end
  end

  defp decode(_marker), do: {:warning, Diagnostic.new(:invalid_marker)}

  defp validate(%{
         "schema" => 2,
         "logical_id" => logical_id,
         "plan_version" => version,
         "approved_planning_commit" => commit
       }) do
    if valid_logical_id?(logical_id) and is_integer(version) and version > 0 and
         valid_commit?(commit) do
      {:ok,
       %__MODULE__{
         schema: 2,
         logical_id: logical_id,
         plan_version: version,
         approved_planning_commit: commit
       }}
    else
      :error
    end
  end

  defp validate(_value), do: :error

  defp valid_logical_id?(value),
    do: is_binary(value) and Regex.match?(~r|^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$|, value)

  defp valid_commit?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{40}$/, value)
end
