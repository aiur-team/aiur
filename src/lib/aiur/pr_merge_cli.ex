defmodule Aiur.PrMergeCLI do
  @moduledoc false
  @usage "Usage: aiur pr merge <N> --reviewed-sha <40-character-sha> [--dry-run] [--approve-body-file <file>] [--inherited <check>]"
  @switches [reviewed_sha: :string, dry_run: :boolean, approve_body_file: :string, inherited: :keep]

  @spec main([String.t()]) :: no_return()
  def main(args) do
    code =
      case parse(args) do
        {:ok, opts} ->
          Aiur.PrMerge.run(opts)

        {:error, message} ->
          IO.puts("REFUSE " <> message)
          2
      end

    System.halt(code)
  end

  @spec parse([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse(args) do
    with {opts, ["merge", number], []} <- OptionParser.parse(args, strict: @switches),
         true <- Regex.match?(~r/\A[1-9][0-9]*\z/, number),
         [sha] <- Keyword.get_values(opts, :reviewed_sha),
         true <- Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha),
         true <- length(Keyword.get_values(opts, :approve_body_file)) <= 1,
         {:ok, body} <- approval_body(opts) do
      {:ok, %{number: String.to_integer(number), reviewed_sha: String.downcase(sha), dry_run: Keyword.get(opts, :dry_run, false), approve_body: body, inherited: Keyword.get_values(opts, :inherited)}}
    else
      _ -> {:error, @usage}
    end
  end

  defp approval_body(opts) do
    case Keyword.fetch(opts, :approve_body_file) do
      :error -> {:ok, nil}
      {:ok, path} -> File.read(path)
    end
  end
end
