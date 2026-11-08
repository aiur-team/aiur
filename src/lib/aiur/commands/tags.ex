defmodule Aiur.Commands.Tags do
  @moduledoc """
  Caller-supplied Command tags: a small, bounded list of slugs such as
  `group:proposal-7` or `source:settings`. A `group:` tag joins sibling
  Commands on one ticket; rejecting one moots the others.
  """

  @max_count 8
  @max_bytes 96
  @pattern ~r/\A[a-z0-9][a-z0-9_-]{0,31}(:[a-z0-9][a-z0-9._-]*)?\z/

  @spec max_count() :: pos_integer()
  def max_count, do: @max_count

  @doc "Validates raw tags; `nil` means none. Order is kept and duplicates dropped."
  @spec normalize(term()) :: {:ok, [String.t()]} | {:error, {:tags, atom()}}
  def normalize(nil), do: {:ok, []}

  def normalize(raw) when is_list(raw) do
    cond do
      not Enum.all?(raw, &is_binary/1) -> {:error, {:tags, :invalid_type}}
      length(raw) > @max_count -> {:error, {:tags, :too_many}}
      Enum.any?(raw, &(byte_size(&1) > @max_bytes)) -> {:error, {:tags, :too_long}}
      not Enum.all?(raw, &Regex.match?(@pattern, &1)) -> {:error, {:tags, :invalid_slug}}
      raw |> Enum.uniq() |> Enum.count(&group?/1) > 1 -> {:error, {:tags, :multiple_groups}}
      true -> {:ok, Enum.uniq(raw)}
    end
  end

  def normalize(_raw), do: {:error, {:tags, :invalid_type}}

  @doc "The Command's `group:` tag, or nil."
  @spec group([String.t()] | nil) :: String.t() | nil
  def group(tags), do: Enum.find(tags || [], &group?/1)

  defp group?(tag), do: String.starts_with?(tag, "group:")
end
