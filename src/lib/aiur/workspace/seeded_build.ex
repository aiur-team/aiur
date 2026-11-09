defmodule Aiur.Workspace.SeededBuild do
  @moduledoc """
  Invalidate path-sensitive first-party BEAMs in a build copied from another checkout.

  A module that embeds an absolute path (for example through a compile-time
  directory macro) keeps
  pointing at the seed checkout after `_build` is copied. Such modules are the
  ones whose literal table contains the seed root. Their beams are removed and
  their sources touched, which is what Mix needs to recompile them (and their
  compile-time dependents) from the new checkout. Every other beam and all
  dependency builds stay warm.
  """

  # Erlang wildcards cannot alternate across "/", so each build root is listed.
  @beam_globs ["_build/*/lib/*/ebin/*.beam", "src/_build/*/lib/*/ebin/*.beam"]

  @spec invalidate_path_sensitive(Path.t(), Path.t()) :: :ok | {:error, term()}
  def invalidate_path_sensitive(seed, checkout) do
    seed_root = physical_path(seed)

    @beam_globs
    |> Enum.flat_map(&Path.wildcard(Path.join(checkout, &1)))
    |> Enum.reduce_while(:ok, fn beam, :ok ->
      case invalidate(beam, seed_root, checkout) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalidate_seeded_beam, beam, reason}}}
      end
    end)
  end

  defp invalidate(beam, seed_root, checkout) do
    with {:ok, relative_source} <- first_party_source(beam, seed_root),
         true <- embeds?(beam, seed_root <> "/"),
         :ok <- File.rm(beam) do
      source = Path.join(checkout, relative_source)
      if File.exists?(source), do: File.touch(source), else: :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  # Dependencies are rebuilt by `mix deps.compile`, not by a missing beam, so only
  # modules compiled from the seed's own sources are invalidated.
  defp first_party_source(beam, seed_root) do
    with {:ok, {_module, [compile_info: info]}} <- :beam_lib.chunks(String.to_charlist(beam), [:compile_info]),
         source when is_list(source) <- info[:source],
         {:ok, relative} <- relative_to(List.to_string(source), seed_root),
         false <- "deps" in Path.split(relative) do
      {:ok, relative}
    else
      _ -> :skip
    end
  end

  defp relative_to(path, root) do
    prefix = root <> "/"
    if String.starts_with?(path, prefix), do: {:ok, String.replace_prefix(path, prefix, "")}, else: :error
  end

  defp embeds?(beam, needle) do
    case :beam_lib.chunks(String.to_charlist(beam), [~c"LitT"]) do
      {:ok, {_module, [{~c"LitT", chunk}]}} -> literals_contain?(chunk, needle)
      _ -> false
    end
  end

  # The literal chunk is stored raw (size 0) or zlib-compressed. An unreadable
  # chunk counts as a match: recompiling is safe, a stale path is not.
  defp literals_contain?(<<0::32, raw::binary>>, needle), do: String.contains?(raw, needle)

  defp literals_contain?(<<_size::32, compressed::binary>>, needle) do
    compressed |> :zlib.uncompress() |> String.contains?(needle)
  rescue
    ErlangError -> true
  end

  defp literals_contain?(_chunk, _needle), do: true

  # Compiled paths come from the build's cwd, which has symlinks resolved.
  defp physical_path(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out, "\n")
      _ -> Path.expand(path)
    end
  end
end
