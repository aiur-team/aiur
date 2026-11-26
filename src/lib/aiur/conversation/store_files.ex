defmodule Aiur.Conversation.StoreFiles do
  @moduledoc false

  alias Aiur.Conversation.Ref
  alias Aiur.Fs

  @doc "Rejects symlinked path components and conversation files before any access."
  @spec check(Path.t()) :: :ok | {:error, term()}
  def check(dir) do
    components = dir |> Path.expand() |> Path.split() |> Enum.scan(&Path.join(&2, &1))

    with :ok <- check_paths(components) do
      case File.ls(dir) do
        {:ok, files} -> check_paths(Enum.map(files, &Path.join(dir, &1)))
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @spec subject(Path.t(), Ref.t(), keyword()) :: :ok | {:error, term()}
  def subject(dir, ref, opts \\ []) do
    path = Path.join(dir, "subject.json")
    expected = subject_record(ref)

    case File.read(path) do
      {:ok, bytes} -> verify_subject(bytes, expected)
      {:error, :enoent} -> create_subject(path, expected, Keyword.get(opts, :file_ops, :file))
      error -> error
    end
  end

  defp check_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, {:symlink_rejected, path}}}
        {:ok, _} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp subject_record(%Ref{subject: :executor} = ref),
    do: %{"v" => 1, "conversation_id" => Ref.conversation_id(ref), "kind" => "executor"}

  defp subject_record(%Ref{subject: {:worker, identity}} = ref) do
    %{
      "v" => 1,
      "conversation_id" => Ref.conversation_id(ref),
      "kind" => "worker",
      "owner" => identity.owner,
      "repository" => identity.repository,
      "identifier" => identity.identifier,
      "provider_id" => identity.provider_id
    }
  end

  defp verify_subject(bytes, expected) do
    with {:ok, actual} <- Jason.decode(bytes),
         true <-
           is_map(actual) and
             Map.drop(actual, ["identifier", "owner", "repository"]) ==
               Map.drop(expected, ["identifier", "owner", "repository"]) do
      :ok
    else
      _ -> {:error, :subject_mismatch}
    end
  end

  defp create_subject(path, record, file_ops) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    bytes = Jason.encode!(record)

    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- File.chmod(tmp, 0o600),
             :ok <- file_ops.write(fd, bytes),
             :ok <- file_ops.sync(fd) do
          publish_subject(tmp, path, record)
        end
      after
        :file.close(fd)
        File.rm(tmp)
      end
    end
  end

  defp publish_subject(tmp, path, record) do
    case File.ln(tmp, path) do
      :ok -> Fs.sync_filesystem()
      {:error, :eexist} -> with {:ok, bytes} <- File.read(path), do: verify_subject(bytes, record)
      error -> error
    end
  end
end
