defmodule Aiur.GitHub.AgentCommentOrigins.Command do
  @moduledoc false

  @type classification :: :comment | :unsupported_compound | :ignored

  @spec classify(String.t()) :: classification()
  def classify(command) when is_binary(command) do
    outside_quotes = outside_quotes(command)

    cond do
      wrapped_shell_comment?(command) ->
        :unsupported_compound

      not comment_candidate?(outside_quotes, command) ->
        :ignored

      shell_compound?(outside_quotes) ->
        :unsupported_compound

      gh_pr_comment?(outside_quotes) or gh_api_comment_post?(outside_quotes, command) ->
        :comment

      true ->
        # A public comment hidden behind an environment wrapper or another
        # shell prefix has no single attributable mutation boundary.
        :unsupported_compound
    end
  end

  def classify(_command), do: :ignored

  @spec comment_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def comment_id(output) when is_binary(output) do
    case output_ids(output) |> Enum.uniq() do
      [comment_id] -> {:ok, comment_id}
      [] -> {:error, :gh_pr_comment_id_missing}
      _ids -> {:error, :ambiguous_gh_pr_comment_ids}
    end
  end

  def comment_id(_output), do: {:error, :gh_pr_comment_id_missing}

  defp comment_candidate?(outside_quotes, command) do
    gh_pr_comment_invocation?(outside_quotes) or
      (gh_api_invocation?(outside_quotes) and api_comment_endpoint?(command) and api_post?(command))
  end

  defp gh_pr_comment?(command) do
    Regex.match?(~r/\A\s*gh\s+pr\s+comment(?:\s|\z)/, command)
  end

  defp gh_pr_comment_invocation?(command) do
    Regex.match?(~r/(?:\A|\s)gh\s+pr\s+comment(?:\s|\z)/, command)
  end

  defp gh_api_comment_post?(outside_quotes, command) do
    Regex.match?(~r/\A\s*gh\s+api(?:\s|\z)/, outside_quotes) and
      api_comment_endpoint?(command) and api_post?(command)
  end

  defp gh_api_invocation?(command), do: Regex.match?(~r/(?:\A|\s)gh\s+api(?:\s|\z)/, command)

  defp api_comment_endpoint?(command), do: Regex.match?(~r{/issues/\d+/comments(?=\s|\z|["'])}, command)
  defp api_post?(command), do: Regex.match?(~r/(?:--method|-X)\s*=?\s*POST\b/i, command)

  defp shell_compound?(command), do: Regex.match?(~r/(?:&&|\|\||[;|]|\r?\n)/, command)

  # `sh -c 'gh pr comment …'` has the same ambiguous wrapper boundary as an
  # environment prefix, but the inner command is deliberately masked by the
  # quote lexer above. Reject this explicit shell-wrapper shape rather than
  # allowing it to bypass pre-execution provenance.
  defp wrapped_shell_comment?(command) do
    Regex.match?(~r/\A\s*(?:ba|z|)sh\s+-c\s+['"].*\bgh\s+(?:pr\s+comment|api)\b/s, command)
  end

  # Preserve only unquoted shell syntax. This is intentionally a small lexer:
  # enough to distinguish an operator from review prose in `--body`, without
  # trying to execute or fully parse a shell command.
  defp outside_quotes(command) do
    command
    |> String.graphemes()
    |> Enum.reduce({:plain, false, []}, &outside_quote_character/2)
    |> then(fn {_mode, _escaped?, characters} -> characters |> Enum.reverse() |> Enum.join() end)
  end

  defp outside_quote_character(_character, {:plain, true, acc}), do: {:plain, false, [" " | acc]}
  defp outside_quote_character(_character, {:double, true, acc}), do: {:double, false, [" " | acc]}
  defp outside_quote_character("\\", {:plain, false, acc}), do: {:plain, true, [" " | acc]}
  defp outside_quote_character("\\", {:double, false, acc}), do: {:double, true, [" " | acc]}
  defp outside_quote_character("'", {:plain, false, acc}), do: {:single, false, [" " | acc]}
  defp outside_quote_character("'", {:single, false, acc}), do: {:plain, false, [" " | acc]}
  defp outside_quote_character("\"", {:plain, false, acc}), do: {:double, false, [" " | acc]}
  defp outside_quote_character("\"", {:double, false, acc}), do: {:plain, false, [" " | acc]}

  defp outside_quote_character(character, {:plain, false, acc}),
    do: {:plain, false, [character | acc]}

  defp outside_quote_character(_character, {mode, false, acc}), do: {mode, false, [" " | acc]}

  defp output_ids(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{} = response} -> json_response_ids(response)
      _other -> raw_output_ids(output)
    end
  end

  defp json_response_ids(response) do
    case response_id(response) do
      {:ok, id} -> [id]
      :missing -> top_level_url_ids(response)
    end
  end

  defp response_id(%{"id" => id}) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp response_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp response_id(_response), do: :missing

  defp top_level_url_ids(response) do
    case Map.get(response, "html_url") do
      url when is_binary(url) -> issue_comment_ids(url)
      _other -> []
    end
  end

  defp raw_output_ids(output) do
    case bare_id(output) do
      {:ok, id} -> [id]
      :error -> issue_comment_ids(output)
    end
  end

  defp issue_comment_ids(value) do
    Regex.scan(~r/#issuecomment-(\d+)\b/, value, capture: :all_but_first) |> List.flatten()
  end

  defp bare_id(output) do
    case Regex.run(~r/\A\s*(\d+)\s*\z/, output) do
      [_, id] -> {:ok, id}
      _ -> :error
    end
  end
end
