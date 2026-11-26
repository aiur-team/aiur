defmodule Aiur.Gateway.StateMigrationCli do
  @moduledoc "`aiur gateway migrate-state [--apply] [--from-key HEX10]`: argv, output and exit code."

  alias Aiur.Gateway.StateMigration
  alias Aiur.Machine.Settings

  @spec main([String.t()], keyword()) :: non_neg_integer()
  def main(argv, opts \\ []) do
    case OptionParser.parse(argv, strict: [apply: :boolean, from_key: :string]) do
      {parsed, [], []} -> run(parsed, opts)
      _ -> fail(64, "usage: aiur gateway migrate-state [--apply] [--from-key <hex10>]")
    end
  end

  defp run(parsed, opts) do
    gateway_key = opts[:gateway_key] || System.get_env("AIUR_INSTANCE_KEY", "")

    with :ok <- check_key(gateway_key),
         :ok <- check_from_key(parsed[:from_key]),
         {:ok, projects} <- projects(opts) do
      plan_opts = [
        state_root: opts[:state_root] || Aiur.TestRunState.decision_state_root(Path.join(File.cwd!(), ".aiur-state")),
        gateway_key: gateway_key,
        home: opts[:home] || System.get_env("HOME"),
        from_key: parsed[:from_key]
      ]

      rows = StateMigration.plan(projects, plan_opts)
      Enum.each(rows, &IO.puts(format(&1)))
      if parsed[:apply], do: apply_rows(rows, plan_opts, opts), else: exit_for(rows)
    else
      {:error, message} -> fail(64, message)
    end
  end

  defp check_key("gw-" <> _), do: :ok
  defp check_key(_), do: {:error, "aiur: not in gateway mode; list projects in ~/.aiur/machine first"}

  defp check_from_key(nil), do: :ok
  defp check_from_key(key), do: if(key =~ ~r/\A[a-f0-9]{10}\z/, do: :ok, else: {:error, "aiur: --from-key must be 10 lowercase hex characters"})

  defp projects(opts) do
    case opts[:projects] || Settings.load() do
      {:ok, %{projects: [_ | _] = list}} -> {:ok, list}
      [_ | _] = list -> {:ok, list}
      {:error, reason} -> {:error, "aiur: ~/.aiur/machine is not usable: #{inspect(reason)}"}
      _ -> {:error, "aiur: no projects: in ~/.aiur/machine"}
    end
  end

  defp apply_rows(rows, plan_opts, opts) do
    live? = opts[:live?] || fn -> live_node?(plan_opts, rows) end

    case StateMigration.apply_plan(rows, live?) do
      :ok -> 0
      {:error, :daemon_running} -> fail(75, "aiur: stop the daemon first (a node for this gateway or one of its projects is up)")
      {:error, {:conflict, _}} -> fail(1, "aiur: conflicts block --apply; resolve them and rerun")
      {:error, {:io, path, reason}} -> fail(1, "aiur: #{path}: #{:file.format_error(reason)}")
    end
  end

  defp exit_for(rows), do: if(Enum.any?(rows, &(&1.kind == :conflict)), do: 1, else: 0)

  # Old nodes are named aiur-$USER-<old key>; a move source's parent directory is the old key.
  defp live_node?(plan_opts, rows) do
    user = System.get_env("USER", "")
    keys = [plan_opts[:gateway_key] | for(%{kind: :move, src: src} <- rows, do: src |> Path.dirname() |> Path.basename())]
    nodes = Enum.map(keys, &"aiur-#{user}-#{&1}")

    case :erl_epmd.names(~c"127.0.0.1") do
      {:ok, names} -> Enum.any?(names, fn {name, _port} -> to_string(name) in nodes end)
      _ -> false
    end
  end

  defp format(%{kind: :move, src: s, dst: d}), do: "move #{s} -> #{d}"
  defp format(%{kind: :copy, src: s, dst: d}), do: "copy #{s} -> #{d}"
  defp format(%{kind: :already_migrated, repo: r}), do: "already_migrated #{r}"
  defp format(%{kind: :nothing, repo: r}), do: "nothing #{r}: no state to move"
  defp format(%{kind: :skipped, repo: r, detail: d}), do: "skipped #{r}: #{d}"
  defp format(%{kind: :conflict, repo: r, detail: d}), do: "conflict #{r}: #{d}"
  defp format(%{kind: :not_migrated, src: s, detail: d}), do: "not migrated #{s}: #{d}"

  defp fail(code, message) do
    IO.puts(:stderr, message)
    code
  end
end
