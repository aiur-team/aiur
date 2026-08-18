defmodule Aiur.Upgrade.Registry.Transport do
  @moduledoc false
  # Injectable transport for fetching aiur-cli npm dist-tags. The default Req
  # implementation talks to the real registry; tests inject a fake that counts
  # calls and returns canned data without touching the network.
  @callback fetch_dist_tags(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
end

defmodule Aiur.Upgrade.Registry.Transport.Req do
  @moduledoc false
  @behaviour Aiur.Upgrade.Registry.Transport

  @impl true
  def fetch_dist_tags(url, timeout_ms) do
    case Req.get(url, timeout: timeout_ms, headers: [accept: "application/json"]) do
      {:ok, %{status: 200, body: body}} ->
        case extract_tags(decode_body(body)) do
          {:ok, tags} -> {:ok, tags}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :malformed_response}
    end
  rescue
    error -> {:error, error}
  end

  # Req decodes JSON bodies into maps; stay defensive against a raw binary.
  defp decode_body(body) when is_map(body), do: body
  defp decode_body(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_body(_other), do: %{}

  # The `/-/package/aiur-cli/dist-tags` endpoint returns a flat tag→version map.
  # Accept a nested `"dist-tags"` too so a full package-doc URL keeps working.
  defp extract_tags(%{"dist-tags" => tags}) when is_map(tags), do: {:ok, tags}
  defp extract_tags(tags) when is_map(tags), do: {:ok, tags}
  defp extract_tags(_other), do: {:error, :missing_dist_tags}
end

defmodule Aiur.Upgrade.Registry do
  @moduledoc """
  Fetches the `aiur-cli` npm dist-tags (`latest`, `next`, `nightly`) that the
  version notice compares against.

  Fail-open by contract: every failure returns `{:error, reason}` and callers
  treat that as "no notice". A bounded timeout keeps an offline host from
  stalling the check (which itself never blocks the daemon — it runs in a
  fire-and-forget task).
  """

  alias Aiur.Upgrade.Registry.Transport

  @registry_url "https://registry.npmjs.org/-/package/aiur-cli/dist-tags"
  @request_timeout_ms 5_000

  @doc """
  Fetch the dist-tags map (e.g. `%{"latest" => "0.0.3", "next" => "0.0.4",
  "nightly" => "0.0.5-nightly.abc"}`) from the registry.

  `AIUR_REGISTRY_URL` overrides the endpoint (used by tests and mirrors); the
  transport defaults to `Aiur.Upgrade.Registry.Transport.Req` and is injectable.
  """
  @spec fetch_dist_tags(module()) :: {:ok, map()} | {:error, term()}
  def fetch_dist_tags(transport \\ Transport.Req) do
    transport.fetch_dist_tags(url(), @request_timeout_ms)
  end

  defp url do
    case System.get_env("AIUR_REGISTRY_URL") do
      value when is_binary(value) and value != "" -> value
      _ -> @registry_url
    end
  end
end
