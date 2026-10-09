defmodule Aiur.Identity.Store do
  @moduledoc """
  Reads the machine identity and publishes its first value without replacing
  an existing file. Unknown fields belong to other machine-store writers.
  """

  require Logger

  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    Keyword.get(opts, :dir) || Application.get_env(:aiur, :machine_state_dir) || default_dir()
  end

  defp default_dir do
    state_dir =
      System.get_env("AIUR_BG_STATE_DIR") ||
        Path.join(System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config"), "aiur")

    Path.join(state_dir, "machine")
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(dir) do
    path = Path.join(dir, "identity.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- Jason.decode(bytes),
         {:ok, identity} <- validate(value) do
      warn_permissions(path)
      {:ok, identity}
    end
  end

  defp validate(%{"schema_version" => 1, "machine_id" => id, "machine_label" => label, "created_at" => created_at})
       when is_binary(id) and is_binary(label) and is_binary(created_at) do
    if Regex.match?(~r/\A[a-z2-7]{26}\z/, id) do
      {:ok, %{machine_id: id, machine_label: label, created_at: created_at}}
    else
      {:error, :invalid_machine_id}
    end
  end

  defp validate(_value), do: {:error, :invalid_identity}

  defp warn_permissions(path) do
    with {:ok, stat} <- File.stat(path) do
      {uid, 0} = System.cmd("id", ["-u"])

      if Bitwise.band(stat.mode, 0o077) != 0 or stat.uid != String.to_integer(String.trim(uid)) do
        Logger.warning("Machine identity has wider permissions or a different owner: #{path}")
      end
    end
  rescue
    error -> Logger.warning("Could not inspect machine identity permissions: #{Exception.message(error)}")
  end

  @spec create(Path.t(), map()) :: :ok | {:error, term()}
  def create(dir, identity) do
    tmp = Path.join(dir, "identity.json.tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fd} <- :file.open(String.to_charlist(tmp), [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(tmp, 0o600),
             :ok <- :file.write(fd, Jason.encode!(identity)),
             :ok <- :file.sync(fd) do
          publish(tmp, Path.join(dir, "identity.json"))
        end
      after
        :file.close(fd)
        File.rm(tmp)
      end
    end
  end

  defp publish(tmp, path) do
    case File.ln(tmp, path) do
      :ok ->
        with :ok <- File.rm(tmp), do: Aiur.Fs.sync_filesystem()

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
