defmodule Aiur.FindingsCLI do
  @moduledoc false

  alias Aiur.Findings

  @type opts ::
          %{unfiled: boolean(), slugs: boolean(), scope: String.t() | nil}
          | %{record: String.t(), repo: String.t()}
          | %{digest: true, scope: String.t() | nil}

  @spec run(opts(), (iodata() -> :ok)) :: non_neg_integer()
  def run(opts, puts \\ &IO.puts/1) do
    do_run(opts, puts)
  end

  defp do_run(%{record: encoded, repo: repo}, puts) do
    with :ok <- validate_repo_slug(repo),
         {:ok, finding} when is_map(finding) <- Jason.decode(encoded),
         :ok <- Findings.append(repo, finding) do
      0
    else
      {:ok, _value} -> write_error(puts, "finding must be a JSON object")
      {:error, %Jason.DecodeError{} = error} -> write_error(puts, Exception.message(error))
      {:error, reason} -> write_error(puts, reason)
    end
  end

  defp do_run(%{digest: true, scope: scope}, puts) do
    case Findings.open(scope: scope) do
      {:ok, findings} ->
        puts.(render_digest(findings))
        0

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp do_run(%{unfiled: unfiled, slugs: slugs, scope: scope}, puts) do
    opts = %{unfiled: unfiled, slugs: slugs, scope: scope}

    reader = if opts.unfiled, do: &Findings.unfiled_with_diagnostics/1, else: &Findings.all_with_diagnostics/1

    case reader.(scope: opts.scope) do
      {:ok, findings, errors} ->
        Enum.each(errors, fn error -> puts.("aiur findings: skipping unreadable ledger entry: #{format_error(error)}") end)
        render_findings(findings, opts, puts)

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp render_findings(findings, %{slugs: true} = opts, puts) do
    findings
    |> Enum.map(& &1["slug"])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(puts)

    exit_code(opts, findings)
  end

  defp render_findings(findings, opts, puts) do
    Enum.each(findings, fn finding -> puts.(Jason.encode!(finding)) end)
    exit_code(opts, findings)
  end

  defp validate_repo_slug(repo) do
    case String.split(repo, "/", parts: 3) do
      [owner, name] when owner not in ["", ".", ".."] and name not in ["", ".", ".."] ->
        if valid_slug_segment?(owner) and valid_slug_segment?(name),
          do: :ok,
          else: {:error, "finding repo must be an owner/repo slug"}

      _ ->
        {:error, "finding repo must be an owner/repo slug"}
    end
  end

  defp valid_slug_segment?(segment), do: String.match?(segment, ~r/\A[A-Za-z0-9._-]+\z/)

  defp render_digest(findings) do
    rows = Enum.map_join(findings, "\n", &digest_row/1)

    [
      "# Open Aiur findings\n\n",
      "| Slug | Scope | Status | Ticket | Observed | Summary |\n",
      "| --- | --- | --- | --- | --- | --- |\n",
      rows,
      if(rows == "", do: "", else: "\n")
    ]
  end

  defp digest_row(finding) do
    ticket = if is_integer(finding["ticket"]), do: "##{finding["ticket"]}", else: "unfiled"

    "| `#{escape_cell(finding["slug"])}` | #{escape_cell(finding["scope"])} | " <>
      "#{escape_cell(finding["status"])} | #{ticket} | #{escape_cell(finding["observed_at"])} | " <>
      "#{escape_cell(finding["summary"])} |"
  end

  defp escape_cell(value), do: value |> to_string() |> String.replace("|", "\\|") |> String.replace(~r/\s+/, " ")

  defp write_error(puts, reason) do
    puts.("aiur findings: #{format_error(reason)}")
    2
  end

  defp exit_code(%{unfiled: true}, findings) when findings != [], do: 1
  defp exit_code(_opts, _findings), do: 0

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
