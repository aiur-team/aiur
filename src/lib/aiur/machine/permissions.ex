defmodule Aiur.Machine.Permissions do
  @moduledoc false

  @spec uid() :: {:ok, non_neg_integer()} | {:error, term()}
  def uid do
    path = Path.join(System.tmp_dir!(), "aiur-owner-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))

    with {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        with {:ok, stat} <- File.stat(path), do: {:ok, stat.uid}
      after
        File.close(file)
        File.rm(path)
      end
    end
  end

  @spec inspect_path(Path.t(), non_neg_integer(), :directory | :regular, function()) :: :ok | {:error, term()}
  def inspect_path(path, uid, type, stat_fun \\ &File.lstat/1) do
    with {:ok, stat} <- stat_fun.(path) do
      cond do
        stat.uid != uid -> {:error, :bad_owner}
        stat.type != type -> {:error, :unsafe_path}
        Bitwise.band(stat.mode, 0o400) == 0 -> {:error, :unreadable}
        true -> :ok
      end
    end
  end

  @spec read(Path.t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def read(path, uid) do
    with :ok <- inspect_path(path, uid, :regular),
         :ok <- private_mode(path) do
      File.read(path)
    end
  end

  defp private_mode(path) do
    with {:ok, stat} <- File.lstat(path) do
      if Bitwise.band(stat.mode, 0o777) == 0o600, do: :ok, else: {:error, :bad_permissions}
    end
  end
end
