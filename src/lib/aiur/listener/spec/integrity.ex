defmodule Aiur.Listener.Spec.Integrity do
  @moduledoc false

  @spec read(Path.t()) :: {:ok, map()} | {:error, :not_installed | :spec_invalid}
  def read(root) do
    if File.exists?(root), do: validate(root), else: {:error, :not_installed}
  end

  defp validate(root) do
    with {:ok, checksum} <- File.read(Path.join(root, "CHECKSUM")),
         {:ok, inventory} <- parse(checksum),
         true <- actual(root) == inventory,
         {:ok, documents} <- decode(root, Map.keys(inventory)),
         true <- manifest_valid?(documents, inventory) do
      {:ok, documents}
    else
      _ -> {:error, :spec_invalid}
    end
  rescue
    _ in [File.Error, ArgumentError] -> {:error, :spec_invalid}
  end

  defp parse(checksum) do
    case String.split(checksum, "\n", trim: true) do
      ["# source aiur-team/khala", "# git_commit " <> sha | rows] ->
        if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: parse_rows(rows), else: :error

      _ ->
        :error
    end
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, &parse_row/2)
  end

  defp parse_row(row, {:ok, acc}) do
    case Regex.run(~r/\A([0-9a-f]{64})  (v1\/.+)\z/, row) do
      [_, hash, path] -> add_row(acc, path, hash)
      _ -> {:halt, :error}
    end
  end

  defp add_row(acc, path, hash) do
    if safe?(path) and not Map.has_key?(acc, path), do: {:cont, {:ok, Map.put(acc, path, hash)}}, else: {:halt, :error}
  end

  defp safe?(path) do
    not String.contains?(path, "\\") and Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp actual(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(directory?(&1) or &1 == Path.join(root, "CHECKSUM")))
    |> Map.new(fn path -> {Path.relative_to(path, root), hash(path)} end)
  end

  defp directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      {:ok, %{type: :regular}} -> false
      _ -> raise ArgumentError, "non-regular spec path"
    end
  end

  defp hash(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp decode(root, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case Jason.decode(File.read!(Path.join(root, path))) do
        {:ok, value} when is_map(value) or is_list(value) -> {:cont, {:ok, Map.put(acc, path, value)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp manifest_valid?(documents, inventory) do
    with %{"spec_version" => "1.0.0", "files" => files} when is_list(files) <- documents["v1/MANIFEST.json"],
         {:ok, manifest} <- manifest_rows(files) do
      manifest == Map.delete(inventory, "v1/MANIFEST.json")
    else
      _ -> false
    end
  end

  defp manifest_rows(files) do
    rows = Enum.map(files, fn %{"path" => path, "sha256" => hash} -> hash <> "  v1/" <> path end)
    parse_rows(rows)
  rescue
    _ in [FunctionClauseError, ArgumentError] -> :error
  end
end
