defmodule Aiur.CLI.Subcommands do
  @moduledoc false
  # Argv evaluation and runners for the findings, ask(s) and --todo subcommands.
  # `Aiur.CLI` owns dispatch; this module owns what those subcommands accept.

  @spec run_todo([String.t()], map()) :: :ok | no_return()
  def run_todo(issue_ids, opts) do
    case Aiur.AgentControlCLI.todo(issue_ids, only: opts.only) do
      0 ->
        :ok

      exit_code ->
        # `--todo` runs under the distribution-free start_clean boot and never
        # starts Aiur's supervision tree. Full application cleanup would touch
        # run-only resources and can print unrelated warnings.
        System.halt(exit_code)
    end
  end

  @spec run_findings(map()) :: :ok | no_return()
  def run_findings(opts) do
    case Aiur.FindingsCLI.run(opts) do
      0 -> :ok
      exit_code -> System.halt(exit_code)
    end
  end

  @spec run_asks(term()) :: :ok | no_return()
  def run_asks(command) do
    case Aiur.AsksCLI.run(command) do
      0 -> :ok
      exit_code -> System.halt(exit_code)
    end
  end

  @spec todo_switch?(keyword()) :: boolean()
  def todo_switch?(opts), do: Keyword.has_key?(opts, :todo) or Keyword.has_key?(opts, :only)

  @spec findings_switch?(keyword()) :: boolean()
  def findings_switch?(opts),
    do: Enum.any?([:unfiled, :slugs, :scope, :record, :repo, :digest], &Keyword.has_key?(opts, &1))

  @spec evaluate_findings(keyword(), [String.t()]) :: tuple()
  def evaluate_findings(opts, positional) do
    if positional == [] do
      evaluate_findings_opts(opts)
    else
      {:error, Aiur.CLI.usage_message()}
    end
  end

  defp evaluate_findings_opts(opts) do
    cond do
      Keyword.has_key?(opts, :record) or Keyword.has_key?(opts, :repo) -> evaluate_findings_record(opts)
      Keyword.has_key?(opts, :digest) -> evaluate_findings_digest(opts)
      true -> evaluate_findings_read(opts)
    end
  end

  defp evaluate_findings_record(opts) do
    if Enum.sort(Keyword.keys(opts)) == [:record, :repo] do
      {:findings, %{record: opts[:record], repo: opts[:repo]}}
    else
      {:error, Aiur.CLI.usage_message()}
    end
  end

  defp evaluate_findings_digest(opts) do
    with true <- Enum.all?(Keyword.keys(opts), &(&1 in [:digest, :scope])),
         true <- opts[:digest] == true,
         {:ok, scope} <- parse_findings_scope(opts[:scope]) do
      {:findings, %{digest: true, scope: scope}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  defp evaluate_findings_read(opts) do
    with true <- Enum.all?(Keyword.keys(opts), &(&1 in [:unfiled, :slugs, :scope])),
         {:ok, scope} <- parse_findings_scope(opts[:scope]) do
      {:findings, %{unfiled: opts[:unfiled] || false, slugs: opts[:slugs] || false, scope: scope}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  defp parse_findings_scope(nil), do: {:ok, nil}
  defp parse_findings_scope(scope) when scope in ["aiur", "repo"], do: {:ok, scope}
  defp parse_findings_scope(_scope), do: :error

  @spec evaluate_ask(keyword(), [String.t()]) :: tuple()
  def evaluate_ask(opts, positional) do
    if Keyword.has_key?(opts, :done), do: evaluate_ask_done(opts, positional), else: evaluate_ask_create(opts, positional)
  end

  defp evaluate_ask_done(opts, positional) do
    with true <- positional == [],
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:done, :note])),
         [id] <- Keyword.get_values(opts, :done),
         true <- String.trim(id) != "",
         true <- single_option?(opts, :note) do
      {:asks, {:done, %{id: id, note: Keyword.get(opts, :note)}}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  defp evaluate_ask_create(opts, positional) do
    with [title] <- positional,
         true <- String.trim(title) != "",
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:body, :body_file, :urgency, :blocking])),
         true <- single_option?(opts, :body),
         true <- single_option?(opts, :body_file),
         true <- not (Keyword.has_key?(opts, :body) and Keyword.has_key?(opts, :body_file)),
         true <- single_option?(opts, :urgency),
         {:ok, body} <- ask_body(opts),
         {:ok, urgency} <- ask_urgency(opts) do
      {:asks, {:create, %{title: title, body: body, urgency: urgency, blocking: Keyword.get(opts, :blocking, false)}}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  @spec evaluate_asks(keyword(), [String.t()]) :: tuple()
  def evaluate_asks(opts, positional) do
    with true <- positional == [],
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:open, :all, :json])),
         true <- not (Keyword.get(opts, :open, false) and Keyword.get(opts, :all, false)) do
      status = if Keyword.get(opts, :all, false), do: :all, else: :open
      {:asks, {:list, %{status: status, json: Keyword.get(opts, :json, false)}}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  defp ask_body(opts) do
    case Keyword.fetch(opts, :body_file) do
      {:ok, path} -> File.read(path)
      :error -> {:ok, Keyword.get(opts, :body)}
    end
  end

  defp ask_urgency(opts) do
    urgency = Keyword.get(opts, :urgency, "normal")
    if urgency in ["low", "normal", "high"], do: {:ok, urgency}, else: :error
  end

  defp single_option?(opts, key), do: length(Keyword.get_values(opts, key)) <= 1

  @spec evaluate_todo(keyword(), [String.t()]) :: tuple()
  def evaluate_todo(opts, positional) do
    with true <- Keyword.get(opts, :todo, false),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:todo, :only])),
         {:ok, issue_ids} <- parse_todo_ids(positional) do
      {:todo, issue_ids, %{only: Keyword.get(opts, :only, false)}}
    else
      _ -> {:error, Aiur.CLI.usage_message()}
    end
  end

  defp parse_todo_ids(positional) do
    issue_ids =
      positional
      |> Enum.flat_map(&String.split(&1, ",", trim: false))
      |> Enum.map(&String.trim/1)

    if issue_ids != [] and Enum.all?(issue_ids, &Regex.match?(~r/^\d+$/, &1)) do
      {:ok, issue_ids |> Enum.map(&canonicalize_todo_id/1) |> Enum.uniq()}
    else
      :error
    end
  end

  # Enumerated issue identifiers are canonical (no leading zeros, see
  # github/issues.ex normalize_issue/4), so a requested ID must match that
  # form or `--only` can mistake the ticket it just queued for one to clear.
  defp canonicalize_todo_id(id), do: id |> String.to_integer() |> Integer.to_string()
end
