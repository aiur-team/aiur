defmodule Aiur.InstanceSummary.ValueGuard do
  @moduledoc false

  alias Aiur.SecretRedactor

  @reason ~r/\A[a-z_]{1,64}\z/
  @credential ~r/\b(?:gh[pousr]_|github_pat_|sk-|Bearer\s)/i
  @opaque_value ~r/(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])|(?<![A-Za-z0-9+\/])[A-Za-z0-9+\/]{48,}={0,2}(?![A-Za-z0-9+\/])/
  @path ~r/(?<![A-Za-z0-9])(?:\/|~\/|[A-Za-z]:\\)/
  @address ~r/(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9-]*:[0-9]+\b|[A-Za-z][A-Za-z0-9+.-]*:\/\//
  @host ~r/(?<![\w.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}(?![\w.-])|\b(?:\d{1,3}\.){3}\d{1,3}\b|\blocalhost\b/i

  @spec reason!(term()) :: :ok
  def reason!(nil), do: :ok

  def reason!(reason) do
    unless is_binary(reason) and Regex.match?(@reason, reason), do: reject!()
    :ok
  end

  @spec check!(String.t()) :: :ok
  def check!(value) do
    if SecretRedactor.redact(value) != value or SecretRedactor.redact_urls(value) != value or
         Enum.any?([@credential, @opaque_value, @path, @host, @address], &Regex.match?(&1, value)),
       do: reject!()

    :ok
  end

  defp reject!, do: raise(ArgumentError, "instance summary contains a forbidden value")
end
