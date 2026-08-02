defmodule Aiur.FindingsCLI do
  @moduledoc false

  alias Aiur.Findings

  @spec run(%{unfiled: boolean(), slugs: boolean(), scope: String.t() | nil}, (iodata() -> :ok)) :: non_neg_integer()
  def run(opts, puts \\ &IO.puts/1) do
    reader = if opts.unfiled, do: &Findings.unfiled/1, else: &Findings.all/1

    case reader.(scope: opts.scope) do
      {:ok, findings} when opts.slugs ->
        findings
        |> Enum.map(& &1["slug"])
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.each(puts)

        exit_code(opts, findings)

      {:ok, findings} ->
        Enum.each(findings, fn finding -> puts.(Jason.encode!(finding)) end)
        exit_code(opts, findings)

      {:error, reason} ->
        puts.("aiur findings: #{format_error(reason)}")
        2
    end
  end

  defp exit_code(%{unfiled: true}, findings) when findings != [], do: 1
  defp exit_code(_opts, _findings), do: 0

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
