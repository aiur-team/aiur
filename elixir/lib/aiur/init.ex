defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  Runs as a foreground, line-based command (never the tmux-backed TUI): it
  prompts for the decisions that branch behavior, writes a pure-YAML
  `.aiurconfig` to the run folder, and — for GitHub trackers — creates the
  labels aiur depends on.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  @config_file_name ".aiurconfig"
  @legacy_file_name "WORKFLOW.md"

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          gets: (String.t() -> String.t() | :eof)
        }

  @type deps :: %{
          existing_config_path: (-> String.t() | nil)
        }

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    run(opts, runtime_io(), runtime_deps())
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    with :ok <- guard_existing_config(opts, deps) do
      io.puts.("Setting up aiur in this repo.")
      :ok
    end
  end

  defp guard_existing_config(%{force: true}, _deps), do: :ok

  defp guard_existing_config(_opts, deps) do
    case deps.existing_config_path.() do
      nil ->
        :ok

      path ->
        {:error,
         "#{Path.basename(path)} already exists at #{path}. " <>
           "Pass --force to overwrite it: aiur init --force"}
    end
  end

  @spec runtime_io() :: io()
  defp runtime_io do
    %{
      puts: fn message -> IO.puts(message) end,
      gets: fn prompt -> IO.gets(prompt) end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      existing_config_path: &existing_config_path/0
    }
  end

  defp existing_config_path do
    cwd = File.cwd!()

    [@config_file_name, @legacy_file_name]
    |> Enum.map(&Path.join(cwd, &1))
    |> Enum.find(&File.regular?/1)
  end
end
