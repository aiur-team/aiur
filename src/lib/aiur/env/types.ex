defmodule Aiur.Env.Types do
  @moduledoc """
  NimbleOptions custom value types used to validate environment-variable
  values.

  Environment variables are always strings, so each type parses the raw
  string into the typed value (`:integer` → integer, `:boolean` → boolean)
  and rejects values that do not parse. The accepted literals mirror what
  the app already recognises at each read site (see `Aiur.Env.Schema`), so a
  correctly configured environment is unaffected; a value that would today
  silently fall back to a default now fails at startup naming the variable.
  """

  @doc """
  Parses a string as a whole integer.

  Accepts any sign-free decimal that occupies the entire string (`"8080"`),
  matching `Integer.parse/1` with an empty remainder — the same shape the
  app's own port/pid readers use. Rejects `"banana"`, `"80x"`, and non-binary
  input.
  """
  @spec integer(binary() | term()) :: {:ok, integer()} | {:error, String.t()}
  def integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "an integer"}
    end
  end

  def integer(_value), do: {:error, "an integer"}

  @doc """
  Parses a string as a boolean literal.

  Truthy literals are `1`, `true`, `yes`; falsy literals are `0`, `false`,
  `no` — case-insensitive, matching the `["1", "true", "yes"]` checks the app
  already uses for `AIUR_DEBUG` / `AIUR_SCREEN_GRAB` / `AIUR_PREWARM_DISABLED`.
  Anything else is a misconfiguration and is rejected rather than silently
  treated as false.
  """
  @spec boolean(binary() | term()) :: {:ok, boolean()} | {:error, String.t()}
  def boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      literal when literal in ["1", "true", "yes"] -> {:ok, true}
      literal when literal in ["0", "false", "no"] -> {:ok, false}
      _ -> {:error, "a boolean (1, true, yes, 0, false, no)"}
    end
  end

  def boolean(_value), do: {:error, "a boolean (1, true, yes, 0, false, no)"}
end
