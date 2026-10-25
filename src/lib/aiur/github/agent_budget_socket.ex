defmodule Aiur.GitHub.AgentBudgetSocket do
  @moduledoc "Local Unix socket that admits agent GitHub requests through the daemon budget."
  use GenServer

  alias Aiur.Config.Paths
  alias Aiur.GitHub.Budget

  @socket_name "agent-github-budget.sock"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec socket_path() :: Path.t()
  def socket_path do
    case Application.get_env(:aiur, :agent_budget_socket_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Paths.runtime_state_dir() do
          {:ok, root} -> Path.join(root, @socket_name)
          _ -> Path.join(System.user_home!(), ".aiur/instances/agent-github-budget.sock")
        end
    end
  end

  @spec request(Path.t(), [String.t()], timeout()) :: {:ok, String.t()} | {:error, term()}
  def request(path, args, timeout \\ 120_000) when is_binary(path) and is_list(args) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:local, :binary, packet: :line, active: false], timeout) do
      {:ok, socket} ->
        result =
          with :ok <- :gen_tcp.send(socket, Jason.encode!(%{args: args}) <> "\n"),
               {:ok, line} <- :gen_tcp.recv(socket, 0, timeout),
               {:ok, %{"status" => 0, "output" => output}} <- Jason.decode(line) do
            {:ok, output}
          else
            {:ok, %{"error" => reason}} -> {:error, reason}
            {:error, reason} -> {:error, reason}
            _ -> {:error, :invalid_response}
          end

        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path, socket_path())
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    _ = File.rm(path)
    listen_path = listen_path(path)
    if listen_path != path, do: File.rm(listen_path)

    case :gen_tcp.listen(0, [:local, :binary, packet: :line, active: false, ifaddr: {:local, String.to_charlist(listen_path)}, backlog: 64]) do
      {:ok, listen_socket} ->
        if listen_path != path, do: File.ln_s!(listen_path, path)
        File.chmod!(path, 0o600)
        command_fun = Keyword.get(opts, :command_fun, &Budget.agent_guard_command/1)
        acceptor = spawn_link(fn -> accept_loop(listen_socket, command_fun) end)
        {:ok, %{path: path, listen_path: listen_path, listen_socket: listen_socket, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:socket_listen_failed, path, listen_path, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{listen_socket: socket, path: path, listen_path: listen_path}) do
    :gen_tcp.close(socket)
    File.rm(path)
    if listen_path != path, do: File.rm(listen_path)
    :ok
  end

  defp listen_path(path) when byte_size(path) <= 100, do: path

  defp listen_path(path) do
    digest = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    Path.join("/tmp", "aiur-budget-#{digest}.sock")
  end

  defp accept_loop(listen_socket, command_fun) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, command_fun) end)
        accept_loop(listen_socket, command_fun)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(50)
        accept_loop(listen_socket, command_fun)
    end
  end

  defp serve(socket, command_fun) do
    response =
      with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
           {:ok, %{"args" => args}} when is_list(args) and length(args) <= 64 <- Jason.decode(line),
           true <- Enum.all?(args, &is_binary/1),
           {:ok, output} <- command_fun.(args) do
        %{status: 0, output: output}
      else
        {:error, reason} -> %{status: 1, error: inspect(reason)}
        _ -> %{status: 1, error: "invalid_request"}
      end

    :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    :gen_tcp.close(socket)
  rescue
    _ -> :gen_tcp.close(socket)
  end
end
