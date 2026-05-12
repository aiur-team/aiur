defmodule SymphonyElixir.Os do
  @moduledoc """
  Runtime-environment helpers that need to be portable across the platforms
  Symphony targets (Linux + macOS).

  The single operation we need is `stty/1` — set termios flags on the
  controlling terminal. We invoke `stty` via `Port.open/2` with
  `:nouse_stdio` so the child inherits BEAM's real fd 0 (the controlling
  terminal). With that inheritance in place, `stty` operates on its own
  stdin by default — no `/proc`-style device lookup, no `-F`/`-f` flag, no
  OS branching.
  """

  @timeout_ms 5_000

  @spec stty([String.t()]) :: :ok | {:error, String.t()}
  def stty(args) do
    case :os.find_executable(~c"stty") do
      false -> {:error, "stty executable not found on PATH"}
      path -> execute(path, args)
    end
  end

  defp execute(executable_path, args) do
    port =
      Port.open({:spawn_executable, executable_path}, [
        :exit_status,
        :nouse_stdio,
        :hide,
        args: args
      ])

    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, "stty #{Enum.join(args, " ")} exited with status #{status}"}
    after
      @timeout_ms ->
        Port.close(port)
        {:error, "stty #{Enum.join(args, " ")} timed out after #{@timeout_ms}ms"}
    end
  rescue
    error in [ErlangError, ArgumentError] ->
      {:error, "stty invocation failed: #{Exception.message(error)}"}
  end
end
