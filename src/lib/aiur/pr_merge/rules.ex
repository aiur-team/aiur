defmodule Aiur.PrMerge.Rules do
  @moduledoc false

  @spec read(function(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def read(api, repo, base, _user) do
    path = "repos/#{repo}/rules/branches/#{URI.encode(base, &URI.char_unreserved?/1)}"

    with {:ok, rules} when is_list(rules) <- api.("get", path, nil),
         true <- Enum.all?(rules, &valid_rule?/1) or {:error, "invalid branch rules observation"},
         true <- not Enum.any?(rules, &(&1["type"] == "workflows")) or {:error, "required workflow rules are not supported; wait for GitHub CI"},
         {:ok, protection} when is_map(protection) <- protection(api, repo, base),
         {:ok, legacy} <- legacy_checks(protection["required_status_checks"]) do
      required = for %{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => checks}} <- rules, check <- checks, do: check_name(check)
      {:ok, %{required: Enum.uniq(required ++ legacy), merge_queue: Enum.any?(rules, &(&1["type"] == "merge_queue"))}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "invalid branch rules observation"}
    end
  end

  defp valid_rule?(%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => checks}}) when is_list(checks),
    do: Enum.all?(checks, &valid_check?/1)

  defp valid_rule?(%{"type" => "required_status_checks"}), do: false
  defp valid_rule?(%{"type" => type}) when is_binary(type), do: type != ""
  defp valid_rule?(_rule), do: false

  defp valid_check?(%{"context" => name}) when is_binary(name), do: name != ""
  defp valid_check?(_check), do: false

  defp legacy_checks(nil), do: {:ok, []}

  defp legacy_checks(%{"checks" => checks}) when is_list(checks) do
    if Enum.all?(checks, &valid_check?/1), do: {:ok, Enum.map(checks, &check_name/1)}, else: {:error, "invalid legacy check observation"}
  end

  defp legacy_checks(%{"contexts" => contexts}) when is_list(contexts) do
    if Enum.all?(contexts, &(is_binary(&1) and &1 != "")), do: {:ok, contexts}, else: {:error, "invalid legacy check observation"}
  end

  defp legacy_checks(_checks), do: {:error, "invalid legacy check observation"}

  defp check_name(%{"context" => name, "integration_id" => id}) when is_integer(id) and id > 0, do: "#{name} (app #{id})"
  defp check_name(%{"context" => name, "app_id" => id}) when is_integer(id) and id > 0, do: "#{name} (app #{id})"
  defp check_name(%{"context" => name}), do: name

  defp protection(api, repo, base) do
    case api.("get", "repos/#{repo}/branches/#{URI.encode(base, &URI.char_unreserved?/1)}/protection", nil) do
      {:error, "GitHub 404:" <> _} -> {:ok, %{}}
      result -> result
    end
  end
end
