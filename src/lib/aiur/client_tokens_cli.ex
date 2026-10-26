defmodule Aiur.ClientTokensCLI do
  @moduledoc false

  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(["create", name | rest]) do
    {opts, positional, invalid} = OptionParser.parse(rest, strict: [scope: :string])

    with true <- positional == [] and invalid == [],
         {:ok, token} <- Aiur.ClientTokens.create(name, opts[:scope] || "write") do
      IO.puts(token)
      :ok
    else
      {:error, reason} -> {:error, "token create failed: #{inspect(reason)}"}
      _ -> {:error, "usage: aiur token create <name> [--scope read|write]"}
    end
  end

  def run(["list"]) do
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
    case Aiur.ClientTokens.revoke(name) do
      :ok ->
        IO.puts("Revoked #{name}.")
        :ok

      {:error, reason} ->
        {:error, "token revoke failed: #{inspect(reason)}"}
    end
  end

  def run(_), do: {:error, "usage: aiur token create <name> [--scope read|write] | list | revoke <name>"}
end
