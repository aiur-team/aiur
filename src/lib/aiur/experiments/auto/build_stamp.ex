defmodule Aiur.Experiments.Auto.BuildStamp do
  @moduledoc false

  @spec read(Path.t() | nil) :: %{source_sha: String.t() | nil, dirty: boolean() | nil}
  def read(release_dir \\ System.get_env("AIUR_RELEASE_DIR"))
  def read(nil), do: %{source_sha: nil, dirty: nil}

  def read(release_dir) do
    case File.read(Path.join(release_dir, "AIUR_BUILD_STAMP")) do
      {:ok, text} -> parse(text)
      {:error, _reason} -> read(nil)
    end
  end

  @spec parse(String.t()) :: %{source_sha: String.t() | nil, dirty: boolean() | nil}
  def parse(text) do
    fields = text |> String.split("\n") |> Enum.flat_map(&field/1) |> Map.new()
    sha = fields["source_sha"]
    sha = if is_binary(sha) and Regex.match?(~r/\A[0-9a-fA-F]+\z/, sha), do: sha, else: nil

    dirty =
      case fields["dirty"] do
        "yes" -> true
        "no" -> false
        _unknown -> nil
      end

    %{source_sha: sha, dirty: dirty}
  end

  @spec repo_root(Path.t() | nil) :: Path.t() | nil
  def repo_root(release_dir \\ System.get_env("AIUR_RELEASE_DIR"))
  def repo_root(nil), do: nil

  def repo_root(release_dir) do
    with {:ok, text} <- File.read(Path.join(release_dir, "AIUR_BUILD_STAMP")), [_, root] <- Regex.run(~r/^repo_root=(.+)$/m, text), do: root, else: (_ -> nil)
  end

  @spec base_version(String.t()) :: String.t() | :unknown
  def base_version(version) do
    case Version.parse(version) do
      {:ok, parsed} -> to_string(%{parsed | pre: [], build: nil})
      :error -> :unknown
    end
  end

  defp field(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key in ["source_sha", "dirty"] -> [{key, value}]
      _invalid -> []
    end
  end
end
