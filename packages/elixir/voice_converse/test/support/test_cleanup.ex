defmodule VoiceConverse.TestCleanup do
  @moduledoc false

  def rm_rf!(path) do
    case File.rm_rf(path) do
      {:ok, _files} -> :ok
      {:error, reason, file} -> raise "could not remove #{file}: #{inspect(reason)}"
    end
  end
end
