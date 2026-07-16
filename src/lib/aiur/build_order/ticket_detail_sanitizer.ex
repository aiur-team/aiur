defmodule Aiur.BuildOrder.TicketDetail.Sanitizer do
  @moduledoc false

  alias Aiur.SecretRedactor

  @sensitive_key_pattern """
  (?:
    authorization
    | proxy-authorization
    | cookie
    | set-cookie
    | [a-z0-9_-]{0,100}(?:
        token
        | secret
        | api[-_]?key
        | credential
        | password
        | passwd
        | passphrase
        | private[-_]?key
      )[a-z0-9_-]{0,100}
  )
  """
  @credential_header_pattern ~r{
    ^\s*
    #{@sensitive_key_pattern}
    \s*:
    \s*[^\r\n]*(?:\n[\t ]+[^\r\n]*)*
  }imux
  @credential_header_name_pattern ~r{
    ^\s*
    #{@sensitive_key_pattern}
    \s*:
  }iux
  @structured_credential_pattern ~r/
    (?:
      (?:"|')?
      #{@sensitive_key_pattern}
      (?:"|')?
      \s*(?::|=>)\s*
      (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^,\]\}\r\n]+)
    )
    |
    (?:
      \{\s*(?:"|')
      #{@sensitive_key_pattern}
      (?:"|')\s*,\s*(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*')\s*\}
    )
  /iux
  @credential_assignment_pattern ~r/
    (?:"|'|&quot;)?
    #{@sensitive_key_pattern}
    (?:"|'|&quot;)?
    \s*=\s*
    (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|&quot;[^\r\n]*?&quot;|[^\s,;\]\}\r\n]+)
  /iux
  @credential_flag_pattern ~r/
    (?<![A-Za-z0-9_-])
    --#{@sensitive_key_pattern}\b
    (?:\s*=\s*|\s+)
    (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s,;\]\}\r\n]+)
  /iux
  @credential_whitespace_pattern ~r/
    (?<![A-Za-z0-9_\/-])
    #{@sensitive_key_pattern}
    \s+
    (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s,;\[\]\}\r\n]+)
  /iux
  @credential_header_pair_pattern ~r/
    \[\s*
    (?:"|'|&quot;)?
    #{@sensitive_key_pattern}
    (?:"|'|&quot;)?
    \s*,\s*
    (?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|&quot;[^\r\n]*?&quot;|[^\]\r\n]+)
    \s*\]
  /iux
  @escaped_credential_header_pair_pattern ~r/
    (?:\[|\{)\s*
    (?:\\"|\\'|&quot;)
    #{@sensitive_key_pattern}
    (?:\\"|\\'|&quot;)
    \s*,\s*
    (?:\\"(?:\\.|[^"])*?\\"|\\'(?:\\.|[^'])*?\\'|&quot;[^\r\n]*?&quot;|[^\]\}\r\n]+)
    \s*(?:\]|\})
  /iux
  @curl_credential_header_pattern ~r/
    (?:-H|--header)\s+(?:"|')
    #{@sensitive_key_pattern}
    \s*:\s*.*?(?:"|')
  /iux
  @credential_pattern ~r/\b(?:bearer|basic)\s+[^\s,;]+/iu
  @private_key_block_pattern ~r/
    -----BEGIN(?:[ ][A-Z0-9]+)*[ ]PRIVATE[ ]KEY(?:[ ]BLOCK)?-----
    .*?
    (?:-----END(?:[ ][A-Z0-9]+)*[ ]PRIVATE[ ]KEY(?:[ ]BLOCK)?-----|\z)
  /isux
  @uri_userinfo_pattern ~r{\b[A-Za-z][A-Za-z0-9+.-]*://[^/\s@]+@}u
  @network_path_userinfo_pattern ~r{(?<![A-Za-z0-9+.-])//[^/\s@]+@}u
  @escaped_structured_credential_pattern ~r{
    \\"
    #{@sensitive_key_pattern}
    \\"
    \s*:\s*
    \\"
    (?:\\.|[^"])*?
    \\"
  }iux
  @entity_structured_credential_pattern ~r/
    &quot;
    #{@sensitive_key_pattern}
    &quot;
    \s*:\s*
    &quot;[^\r\n]*?&quot;
  /iux
  @credential_element_pattern ~r{
    <\s*(?:[A-Za-z][A-Za-z0-9:_-]*:)?
    #{@sensitive_key_pattern}\b[^>]*>
    (?:[^<]|<!\[CDATA\[(?s:.*?)\]\]>)*
    <\s*/\s*[^>]+>
    |
    <\s*(?:[A-Za-z][A-Za-z0-9:_-]*:)?
    #{@sensitive_key_pattern}
    \b[^>]*\bvalue\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*>
    |
    <[^>]*\b(?:name|id|key)\s*=\s*(?:"|')
    #{@sensitive_key_pattern}
    (?:"|')[^>]*\bvalue\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*>
    |
    <[^>]*\bvalue\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*\b(?:name|id|key)\s*=\s*(?:"|')
    #{@sensitive_key_pattern}
    (?:"|')[^>]*>
    |
    <[^>]*\b#{@sensitive_key_pattern}\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*>
  }iux
  @malformed_credential_element_pattern ~r{
    <\s*(?:[A-Za-z][A-Za-z0-9:_-]*:)?
    #{@sensitive_key_pattern}\b
    (?:[^>]*>(?s:.*)|[^>]*?)\z
  }iux
  @file_uri_pattern ~r{\bfile:(?://)?/[^\s"')\],\}]+}iu
  @unc_path_pattern ~r{
    (?<!:)(?<![A-Za-z0-9+.-])
    (?:\\\\|//)[^\\/\s]+(?:[\\/][^\s"')\],\}]+)+
  }ux
  @sensitive_local_root_pattern ~r{
    (?<![A-Za-z0-9._/-])
    /(?:etc|home|opt|root|usr|var|workspace|tmp)(?:/[A-Za-z0-9._@%+=,-]+)*
    (?![A-Za-z0-9._/-])
  }ux
  @absolute_local_path_pattern ~r{
    (?<![A-Za-z0-9._/-])
    /(?!/)[A-Za-z0-9._-]+(?:/[A-Za-z0-9._@%+=,-]+)+
  }ux

  @spec sanitize(String.t(), pos_integer()) :: {:ok, String.t()} | :error
  def sanitize(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if byte_size(value) <= limit and String.valid?(value) do
      sanitized =
        value
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
        |> decode_structural_escapes()
        |> SecretRedactor.redact()
        |> redact_credentials()
        |> redact_local_paths()

      if byte_size(sanitized) <= limit, do: {:ok, sanitized}, else: :error
    else
      :error
    end
  end

  def sanitize(_value, _limit), do: :error

  defp redact_credentials(value) do
    value = redact_folded_headers(value)
    value = Regex.replace(@private_key_block_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@uri_userinfo_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@network_path_userinfo_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@escaped_structured_credential_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@entity_structured_credential_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_element_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@malformed_credential_element_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@curl_credential_header_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@escaped_credential_header_pair_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_header_pair_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@structured_credential_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_flag_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_whitespace_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_assignment_pattern, value, "[REDACTED:credential]")
    value = Regex.replace(@credential_header_pattern, value, "[REDACTED:credential]")
    Regex.replace(@credential_pattern, value, "[REDACTED:credential]")
  end

  defp redact_folded_headers(value) do
    {lines, _sensitive_header?} =
      value
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], false}, fn line, {lines, sensitive_header?} ->
        cond do
          Regex.match?(@credential_header_name_pattern, line) ->
            {["[REDACTED:credential]" | lines], true}

          sensitive_header? and Regex.match?(~r/^[\t ]/u, line) ->
            {lines, true}

          true ->
            {[line | lines], false}
        end
      end)

    lines
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp redact_local_paths(value) do
    value = Regex.replace(@file_uri_pattern, value, "[REDACTED:local_path]")
    value = Regex.replace(@unc_path_pattern, value, "[REDACTED:local_path]")
    value = Regex.replace(@sensitive_local_root_pattern, value, "[REDACTED:local_path]")
    value = Regex.replace(@absolute_local_path_pattern, value, "[REDACTED:local_path]")
    value = Regex.replace(~r{~/[^\s"')\],\}]+}u, value, "[REDACTED:local_path]")
    Regex.replace(~r{[A-Za-z]:\\[^\s]+}u, value, "[REDACTED:local_path]")
  end

  defp decode_structural_escapes(value) do
    value =
      Regex.replace(~r/\\u00([0-7][0-9A-Fa-f])/u, value, fn match, hex ->
        decode_ascii_escape(match, hex)
      end)

    Regex.replace(~r/&#(?:x([0-7][0-9A-Fa-f])|([0-9]{1,3}));/iu, value, fn match, hex, decimal ->
      decode_entity(match, hex, decimal)
    end)
  end

  defp decode_ascii_escape(match, hex) do
    case String.to_integer(hex, 16) do
      codepoint when codepoint in 32..126 -> <<codepoint>>
      _ -> match
    end
  end

  defp decode_entity(match, hex, _decimal) when hex != "", do: decode_ascii_escape(match, hex)

  defp decode_entity(match, _hex, decimal) do
    case Integer.parse(decimal) do
      {codepoint, ""} when codepoint in 32..126 -> <<codepoint>>
      _ -> match
    end
  end
end
