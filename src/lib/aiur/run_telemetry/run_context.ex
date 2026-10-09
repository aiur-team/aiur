defmodule Aiur.RunTelemetry.RunContext do
  @moduledoc "Content-free build and effective configuration identity for a telemetry boot."

  @secret ~r/(?:sk[-_][A-Za-z0-9]|ghp_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|secret|password|credential|bearer|authorization|api[-_]?key|prompt|token)/i
  @volatile ~w(refresh_ms render_interval_ms telemetry_retention_prune_interval_bytes)

  @spec current() :: map()
  def current do
    settings =
      case Aiur.Config.settings() do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    build(settings)
  end

  @spec build(map(), keyword()) :: map()
  def build(settings, opts \\ []) do
    canonical = canonical(settings)
    stamp = read_stamp(Keyword.get(opts, :stamp_path, Path.join(to_string(:code.root_dir()), "AIUR_BUILD_STAMP")))

    %{
      aiur_vsn: to_string(Keyword.get(opts, :vsn, Application.spec(:aiur, :vsn) || "unknown")),
      build_sha: Map.get(stamp, "source_sha", "unknown"),
      package_version: Map.get(stamp, "package_version", "unknown"),
      config_hash: hash(canonical),
      config_section_hashes: Map.new(canonical, fn {key, value} -> {key, hash(value)} end),
      capture_tags: get_in(canonical, ["observability", "capture_tags"]) || %{}
    }
  end

  defp canonical(%{__struct__: _} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _} -> Regex.match?(@secret, to_string(key)) or to_string(key) in @volatile end)
    |> Map.new(fn {key, value} -> {to_string(key), canonical(value)} end)
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  # Encode sorted objects explicitly; map enumeration order is not a JSON contract.
  defp encode(value) when is_map(value) do
    entries = value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, value} -> [Jason.encode!(key), ":", encode(value)] end)
    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp encode(value) when is_list(value), do: ["[", Enum.intersperse(Enum.map(value, &encode/1), ","), "]"]
  defp encode(value), do: Jason.encode!(value)
  defp hash(value), do: :crypto.hash(:sha256, encode(value)) |> Base.encode16(case: :lower)

  defp read_stamp(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> Enum.flat_map(&stamp_entry/1) |> Map.new()
      {:error, _reason} -> %{}
    end
  end

  defp stamp_entry(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key in ["source_sha", "package_version"] and value != "" -> [{key, value}]
      _ -> []
    end
  end
end
