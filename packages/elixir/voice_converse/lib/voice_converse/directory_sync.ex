defmodule VoiceConverse.DirectorySync do
  @moduledoc "Durable directory entries without flushing unrelated filesystems."

  @spec sync(Path.t()) :: :ok | {:error, term()}
  def sync(directory) do
    with {:ok, fd} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  @doc "Syncs child before parent, including ancestors created by mkdir_p."
  @spec ancestors(Path.t()) :: :ok | {:error, term()}
  def ancestors(directory) do
    directory = Path.expand(directory)

    with :ok <- sync(directory) do
      parent = Path.dirname(directory)
      if parent == directory, do: :ok, else: ancestors(parent)
    end
  end
end
