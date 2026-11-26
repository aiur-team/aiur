defmodule Aiur.RepoBase.Ledger do
  @moduledoc false

  @type validator :: {module(), atom()} | nil

  @spec validator(atom()) :: validator()
  def validator(kind), do: Application.get_env(:aiur, :repo_ledger_validators, %{})[kind]

  @spec read_ledger(Path.t(), atom(), validator()) :: {:ok, String.t()} | {:error, term()}
  def read_ledger(path, kind, validator) do
    with {:ok, contents} <- File.read(path),
         :ok <- validate(contents, path, kind, validator) do
      {:ok, contents}
    end
  end

  @spec validate(String.t(), Path.t(), atom(), validator()) :: :ok | {:error, term()}
  def validate(_contents, _path, kind, nil), do: {:error, {:no_validator, kind}}

  def validate(contents, path, :findings, {module, function}) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {line, line_number}, :ok ->
      with {:ok, finding} when is_map(finding) <- Jason.decode(line),
           :ok <- apply(module, function, [finding]) do
        {:cont, :ok}
      else
        _ -> {:halt, invalid(path, :findings, line_number)}
      end
    end)
  end

  def validate(contents, path, kind, validator) do
    with {:ok, records} <- decode_records(contents, path, kind) do
      validate_records(records, path, kind, validator)
    end
  end

  defp decode_records(contents, path, kind) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, records} ->
      case Jason.decode(line) do
        {:ok, record} when is_map(record) -> {:cont, {:ok, [record | records]}}
        _ -> {:halt, invalid(path, kind, line_number)}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp validate_records(records, path, :asks, {module, function}) do
    case apply(module, function, [records]) do
      :ok -> :ok
      {:error, {line_number, _reason}} -> invalid(path, :asks, line_number)
    end
  end

  defp invalid(path, :asks, line), do: {:error, {:invalid_asks_ledger, path, line}}
  defp invalid(path, :findings, line), do: {:error, {:invalid_findings_ledger, path, line}}
end
