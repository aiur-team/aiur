defmodule Aiur.Findings do
  @moduledoc """
  Durable executor findings stored as bounded NDJSON records in repository state
  nodes. Records are intentionally host-local; readers aggregate sibling nodes
  only when asked, so there is no second global copy to reconcile.
  """

  alias Aiur.RepoBase

  @max_record_bytes 4 * 1024
  @scopes ~w(aiur repo)
  @statuses ~w(open filed resolved)

  @type record :: %{required(String.t()) => term()}

  @doc "Appends one validated finding with `O_APPEND` semantics."
  @spec append(String.t(), record()) :: :ok | {:error, term()}
  def append(repo_url, finding) when is_binary(repo_url) and is_map(finding) do
    with :ok <- RepoBase.ensure_state_tree(repo_url),
         {:ok, encoded} <- encode(finding),
         :ok <- append_line(RepoBase.findings_path(repo_url), encoded <> "\n") do
      :ok
    end
  end

  @doc "Returns findings from all repository nodes on this host."
  @spec all(keyword()) :: {:ok, [record()]} | {:error, term()}
  def all(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    with :ok <- validate_scope_filter(scope) do
      [RepoBase.repo_path("placeholder/placeholder"), "..", "..", "*", "*", "meta", "findings.ndjson"]
      |> Path.join()
      |> Path.expand()
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, findings} ->
        case read_file(path) do
          {:ok, records} -> {:cont, {:ok, findings ++ filter_scope(records, scope)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "Returns sorted unique finding slugs across all repository nodes on this host."
  @spec slugs(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def slugs(opts \\ []) do
    with {:ok, findings} <- all(opts) do
      {:ok, findings |> Enum.map(& &1["slug"]) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc "Returns findings that have not been promoted to a ticket yet."
  @spec unfiled(keyword()) :: {:ok, [record()]} | {:error, term()}
  def unfiled(opts \\ []) do
    with {:ok, findings} <- all(opts) do
      {:ok, Enum.filter(findings, &(Map.get(&1, "ticket") in [nil, ""]))}
    end
  end

  @doc false
  @spec validate(record()) :: :ok | {:error, String.t()}
  def validate(finding) when is_map(finding) do
    with :ok <- required_string(finding, "slug"),
         :ok <- required_string(finding, "observed_at"),
         :ok <- validate_scope(Map.get(finding, "scope")),
         :ok <- required_string(finding, "observed_in"),
         :ok <- required_string(finding, "instance"),
         :ok <- required_string(finding, "summary"),
         :ok <- validate_evidence(Map.get(finding, "evidence")),
         :ok <- required_string(finding, "cost"),
         :ok <- validate_ticket(Map.get(finding, "ticket")),
         :ok <- validate_status(Map.get(finding, "status")) do
      :ok
    end
  end

  def validate(_finding), do: {:error, "finding must be a JSON object"}

  defp encode(finding) do
    with :ok <- validate(finding),
         {:ok, encoded} <- Jason.encode(finding),
         :ok <- validate_size(encoded <> "\n") do
      {:ok, encoded}
    end
  end

  defp validate_size(line) when byte_size(line) <= @max_record_bytes, do: :ok

  defp validate_size(line),
    do: {:error, "finding exceeds the #{@max_record_bytes}-byte atomic append limit (got #{byte_size(line)} bytes)"}

  defp append_line(path, line) do
    case File.open(path, [:append, :binary]) do
      {:ok, device} ->
        try do
          File.write(device, line)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:finding_append_open_failed, path, reason}}
    end
  end

  defp read_file(path) do
    path
    |> File.stream!([], :line)
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, records} ->
      case Jason.decode(String.trim_trailing(line, "\n")) do
        {:ok, finding} when is_map(finding) ->
          case validate(finding) do
            :ok -> {:cont, {:ok, records ++ [finding]}}
            {:error, reason} -> {:halt, {:error, {:invalid_finding_record, path, line_number, reason}}}
          end

        _ ->
          {:halt, {:error, {:invalid_finding_record, path, line_number, "invalid JSON"}}}
      end
    end)
  rescue
    error in File.Error -> {:error, {:finding_read_failed, path, error.reason}}
  end

  defp filter_scope(records, nil), do: records
  defp filter_scope(records, scope), do: Enum.filter(records, &(&1["scope"] == scope))

  defp validate_scope_filter(nil), do: :ok
  defp validate_scope_filter(scope), do: validate_scope(scope)

  defp required_string(finding, key) do
    case Map.get(finding, key) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0, do: :ok, else: {:error, "finding requires non-empty #{key}"}

      _ ->
        {:error, "finding requires non-empty #{key}"}
    end
  end

  defp validate_scope(scope) when scope in @scopes, do: :ok
  defp validate_scope(_scope), do: {:error, "finding scope must be one of: #{Enum.join(@scopes, ", ")}"}

  defp validate_evidence(evidence) when is_list(evidence) and evidence != [] do
    if Enum.all?(evidence, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "finding evidence must be non-empty string references"}
  end

  defp validate_evidence(_evidence), do: {:error, "finding requires non-empty evidence references"}

  defp validate_ticket(nil), do: :ok
  defp validate_ticket(ticket) when is_integer(ticket) and ticket > 0, do: :ok
  defp validate_ticket(_ticket), do: {:error, "finding ticket must be a positive issue number or null"}

  defp validate_status(status) when status in @statuses, do: :ok
  defp validate_status(_status), do: {:error, "finding status must be one of: #{Enum.join(@statuses, ", ")}"}
end
