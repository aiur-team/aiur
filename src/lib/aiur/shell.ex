defmodule Aiur.Shell do
  @moduledoc """
  Single canonical POSIX single-quote shell escaping.

  This is the ONLY shell-escape implementation in the codebase. Every
  Elixir call site that splices a value into a `sh`/`bash -c` command
  string must use `escape/1`, or `escape/2` with `fast_path: true` when
  human-readable output is wanted for values that are already shell-safe.

  Canonical dialect: wrap the value in single quotes and splice embedded
  single quotes as `'"'"'` (close quote, double-quoted single quote,
  reopen). Note: single-quoting does not neutralize NUL bytes; callers
  must not pass NUL-containing values.

  Shell scripts cannot call this module. Any quoting helper added to a
  shell script must carry a comment pointing at `Aiur.Shell.escape/1` as
  the canonical semantics to mirror. As of this module's creation, no
  shell script in the repo implements shell quoting.
  """

  @fast_path_charset ~r/^[A-Za-z0-9_\/:.,=@%+-]+$/

  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @spec escape(String.t(), fast_path: boolean()) :: String.t()
  def escape(value, opts) when is_binary(value) and is_list(opts) do
    if Keyword.get(opts, :fast_path, false) and String.match?(value, @fast_path_charset) do
      value
    else
      escape(value)
    end
  end
end
