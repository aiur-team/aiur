defmodule Aiur.Config.Schema.Errors do
  @moduledoc "Flattens a settings changeset's nested errors into the dotted string carried by {:invalid_workflow_config, msg}."

  import Ecto.Changeset, only: [traverse_errors: 2]

  @spec format_errors(Ecto.Changeset.t()) :: String.t()
  def format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  @spec flatten_errors(map() | list(), String.t() | nil) :: [String.t()]
  def flatten_errors(errors, prefix \\ nil)

  def flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  def flatten_errors(errors, prefix) when is_list(errors) and is_binary(prefix) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  @spec error_value_to_string(term()) :: String.t()
  def error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  def error_value_to_string(value), do: inspect(value)
end
