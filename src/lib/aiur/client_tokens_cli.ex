defmodule Aiur.ClientTokensCLI do
  @moduledoc false

  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(["create", name | rest]) do
    {opts, positional, invalid} = OptionParser.parse(rest, strict: [scope: :string])

    with true <- positional == [] and invalid == [],
         :ok <- select_project_workflow(),
         {:ok, token} <- Aiur.ClientTokens.create(name, opts[:scope] || "write") do
      IO.puts(token)
      :ok
    else
      {:error, reason} -> {:error, "token create failed: #{inspect(reason)}"}
      _ -> {:error, "usage: aiur token create <name> [--scope read|write]"}
    end
  end

  def run(["list"]) do
    :ok = select_project_workflow()

    case Aiur.ClientTokens.list() do
      {:ok, tokens} ->
        if tokens == [], do: IO.puts("No client tokens.")
        Enum.each(tokens, &IO.puts("#{&1["name"]}\t#{&1["scope"]}\t#{&1["created_at"]}"))
        :ok

      {:error, reason} ->
        {:error, "token list failed: #{inspect(reason)}"}
    end
  end

  def run(["revoke", name]) do
    :ok = select_project_workflow()

    case Aiur.ClientTokens.revoke(name) do
      :ok ->
        IO.puts("Revoked #{name}.")
        :ok

      {:error, reason} ->
        {:error, "token revoke failed: #{inspect(reason)}"}
    end
  end

  def run(_), do: {:error, "usage: aiur token create <name> [--scope read|write] | list | revoke <name>"}

  defp select_project_workflow do
    case System.get_env("AIUR_PROJECT_ROOT") do
      root when is_binary(root) and root != "" ->
        root
        |> project_workflow_path()
        |> Aiur.Workflow.set_workflow_file_path()

      _ ->
        :ok
    end
  end

  defp project_workflow_path(root) do
    [_cwd_config, _cwd_legacy, global_config, global_legacy] =
      Aiur.Workflow.config_path_candidates()

    Aiur.Workflow.resolve_config_path([
      Path.join([root, ".aiur", "config"]),
      Path.join(root, ".aiurconfig"),
      global_config,
      global_legacy
    ])
  end
end
