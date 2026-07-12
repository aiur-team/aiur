defmodule Aiur.DecisionArtifact do
  @moduledoc """
  Validates a single Decision artifact reference: a local path must be
  absolute and canonicalize (symlink-resolved) beneath one of the
  caller-supplied safe roots; a remote reference must be an HTTPS URL
  with no embedded credentials and a host that exactly matches, or is a
  dot-delimited subdomain of, an approved host.

  File-serving consumers must re-canonicalize and re-check containment
  at access time — validating here only proves containment at
  ingestion, not that a later symlink swap can't reintroduce escape.
  """

  alias Aiur.PathSafety

  @default_allowed_hosts ~w(github.com api.github.com raw.githubusercontent.com)

  @type t :: %{kind: :path | :url, value: String.t()}

  @doc """
  Validates `value` as either an absolute local path contained by one
  of `safe_roots`, or an allowlisted HTTPS URL.
  """
  @spec validate(String.t(), [Path.t()]) :: {:ok, t()} | {:error, atom()}
  def validate(value, safe_roots) when is_binary(value) and is_list(safe_roots) do
    case classify(value) do
      :url -> validate_url(value)
      :path -> validate_path(value, safe_roots)
      :invalid -> {:error, :artifact_invalid}
    end
  end

  defp classify(value) do
    cond do
      String.starts_with?(value, "https://") -> :url
      String.starts_with?(value, "http://") -> :url
      String.contains?(value, "://") -> :invalid
      value == "" -> :invalid
      true -> :path
    end
  end

  defp validate_path(value, safe_roots) do
    if Path.type(value) != :absolute do
      {:error, :artifact_path_not_absolute}
    else
      with {:ok, canonical} <- PathSafety.canonicalize(value) do
        if within_any_root?(canonical, safe_roots) do
          {:ok, %{kind: :path, value: canonical}}
        else
          {:error, :artifact_path_outside_root}
        end
      else
        {:error, _reason} -> {:error, :artifact_path_unreadable}
      end
    end
  end

  defp within_any_root?(canonical, safe_roots) do
    Enum.any?(safe_roots, fn root ->
      case PathSafety.canonicalize(root) do
        {:ok, canonical_root} ->
          canonical == canonical_root or
            String.starts_with?(canonical <> "/", canonical_root <> "/")

        _ ->
          false
      end
    end)
  end

  defp validate_url(value) do
    uri = URI.parse(value)

    cond do
      uri.scheme != "https" -> {:error, :artifact_url_insecure_scheme}
      uri.userinfo not in [nil, ""] -> {:error, :artifact_url_has_credentials}
      not allowed_host?(uri.host) -> {:error, :artifact_url_host_not_allowed}
      true -> {:ok, %{kind: :url, value: value}}
    end
  end

  defp allowed_host?(nil), do: false

  defp allowed_host?(host) when is_binary(host) do
    downcased = String.downcase(host)

    Enum.any?(configured_allowed_hosts(), fn allowed ->
      downcased == allowed or String.ends_with?(downcased, "." <> allowed)
    end)
  end

  defp configured_allowed_hosts do
    Application.get_env(:aiur, :decision_artifact_allowed_hosts, @default_allowed_hosts)
  end
end
