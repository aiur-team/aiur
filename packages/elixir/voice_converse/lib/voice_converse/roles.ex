defmodule VoiceConverse.Roles do
  @moduledoc """
  Loads host-supplied inline roles and Markdown files with YAML front matter.
  Directory roles override inline roles by id. Loading returns warnings for skipped
  files and duplicate ids; a missing directory is allowed. No host content is built in.
  """

  alias VoiceConverse.Config

  @type role :: %{id: String.t(), title: String.t(), prompt: String.t(), hash: String.t(), targets: [String.t()]}

  @spec list(Config.t()) :: [map()]
  def list(config), do: config |> load() |> Map.fetch!(:roles) |> Enum.map(&Map.take(&1, [:id, :title, :targets]))

  @spec get(Config.t(), String.t()) :: {:ok, role()} | {:error, :not_found}
  def get(config, id) do
    case Enum.find(load(config).roles, &(&1.id == id)) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  @spec load(Config.t()) :: %{roles: [role()], warnings: [map()]}
  def load(%Config{} = config) do
    inline = Enum.with_index(config.roles, fn role, index -> {"inline:#{index}", normalize(role)} end)
    {files, warnings} = files(config.roles_dir)

    {roles, warnings} =
      Enum.reduce(inline ++ files, {%{}, warnings}, fn {source, result}, {roles, warnings} ->
        case result do
          {:ok, role} ->
            warnings =
              if Map.has_key?(roles, role.id),
                do: warnings ++ [%{source: source, reason: :duplicate_id, id: role.id}],
                else: warnings

            {Map.put(roles, role.id, role), warnings}

          {:error, reason} ->
            {roles, warnings ++ [%{source: source, reason: reason}]}
        end
      end)

    roles = roles |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&with_glossary(&1, config.glossary))
    %{roles: roles, warnings: warnings}
  end

  defp files(nil), do: {[], []}

  defp files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        files = names |> Enum.filter(&(Path.extname(&1) == ".md" and not String.starts_with?(&1, "_"))) |> Enum.sort()

        {Enum.map(files, fn name ->
           path = Path.join(dir, name)
           {path, read(path)}
         end), []}

      {:error, :enoent} ->
        {[], []}

      {:error, reason} ->
        {[], [%{source: dir, reason: reason}]}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(text) do
    with [_, yaml, body] <- Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/s, text),
         {:ok, metadata} when is_map(metadata) <- YamlElixir.read_from_string(yaml) do
      normalize(%{
        id: metadata["id"],
        title: metadata["title"],
        targets: metadata["targets"],
        prompt: String.trim(body)
      })
    else
      _ -> {:error, :invalid_front_matter}
    end
  end

  defp normalize(%{id: id, title: title, prompt: prompt} = role) do
    targets = Map.get(role, :targets, ["worker", "executor"])

    if Enum.all?([id, title, prompt], &(is_binary(&1) and String.trim(&1) != "")) and
         is_list(targets) and targets != [] and Enum.all?(targets, &(&1 in ["worker", "executor"])) do
      {:ok, %{id: id, title: title, prompt: prompt, targets: targets}}
    else
      {:error, :invalid_role}
    end
  end

  defp normalize(_), do: {:error, :invalid_role}

  defp with_glossary(role, glossary) do
    prompt = Enum.join([role.prompt | List.wrap(glossary)], "\n\n")
    Map.merge(role, %{prompt: prompt, hash: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)})
  end
end
