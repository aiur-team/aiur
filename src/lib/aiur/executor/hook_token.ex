defmodule Aiur.Executor.HookToken do
  @moduledoc """
  Instance-scoped credential shared by Executor hook and delivery endpoints.

  `ensure/0` preserves an existing token and repairs its curl header file;
  `rotate/0` replaces both files with individually atomic, private writes.
  Consumers use `curl -H @<headers_path>` so the token never appears in argv.
  `read/0` returns `{:ok, token}` or a filesystem/validation error; it never creates state.
  """
  alias Aiur.Executor.SessionRecord
  alias Aiur.Fs

  @spec path() :: Path.t()
  def path do
    key = System.get_env("AIUR_INSTANCE_KEY")
    if key in [nil, ""], do: raise(ArgumentError, "Executor hook requires an instance key")
    String.replace_suffix(SessionRecord.path(key), ".session.json", ".hook-token")
  end

  @spec headers_path() :: Path.t()
  def headers_path, do: String.replace_suffix(path(), ".hook-token", ".hook-headers")

  @spec read() :: {:ok, String.t()} | {:error, term()}
  def read do
    with {:ok, token} <- File.read(path()) do
      if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, token), do: {:ok, token}, else: {:error, :invalid_token}
    end
  rescue
    ArgumentError -> {:error, :unconfigured}
  end

  @spec ensure() :: :ok | {:error, term()}
  def ensure, do: locked(fn -> with {:ok, token} <- existing_or_new(), do: write(token) end)

  @spec rotate() :: :ok | {:error, term()}
  def rotate, do: locked(fn -> write(new_token()) end)

  defp locked(fun), do: :global.trans({{__MODULE__, path()}, self()}, fun)
  defp new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp existing_or_new do
    case read() do
      {:error, :enoent} -> {:ok, new_token()}
      result -> result
    end
  end

  defp write(token) do
    with :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- File.chmod(Path.dirname(path()), 0o700),
         :ok <- Fs.atomic_write(path(), token, mode: 0o600, fsync: true) do
      Fs.atomic_write(headers_path(), "Authorization: Bearer #{token}\n", mode: 0o600, fsync: true)
    end
  end
end
