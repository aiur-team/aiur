defmodule Aiur.Conversation.SubjectIndex do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Conversation.{HistoryReader, Ref, StoreFiles}
  alias Aiur.TrackerIdentity

  @table :aiur_conversation_subjects
  @unreadable_subject_topic "system.conversation.subject_index.unreadable"

  @spec put(Path.t(), Ref.t()) :: :ok
  def put(dir, %Ref{subject: {:worker, identity}} = ref) do
    key = {Path.dirname(dir), String.downcase(identity.owner), String.downcase(identity.repository), identity.identifier, Ref.conversation_id(ref)}
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, true})
    :ok
  end

  def put(_dir, _ref), do: :ok

  @spec resolve(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()} | {:error, :ambiguous_subject, [String.t()]}
  def resolve(owner, repository, identifier) do
    with {:ok, root} <- Paths.conversation_state_dir(),
         true <- :ets.whereis(@table) != :undefined,
         :ok <- load(root) do
      ids =
        :ets.match(
          @table,
          {{root, String.downcase(owner), String.downcase(repository), identifier, :"$1"}, true}
        )
        |> List.flatten()
        |> Enum.sort()

      readable(ids)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp readable(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case HistoryReader.snapshot(id) do
        {:ok, _} -> {:cont, {:ok, [id | acc]}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :not_found}
      {:ok, [id]} -> {:ok, id}
      {:ok, ids} -> {:error, :ambiguous_subject, Enum.sort(ids)}
      error -> error
    end
  end

  defp load(root) do
    if :ets.member(@table, {:loaded, root}) do
      :ok
    else
      with :ok <- StoreFiles.check(root),
           {:ok, names} <- directories(root) do
        bad_count = load_names(root, names)
        :ets.insert(@table, {{:loaded, root}, true})
        log_bad_count(bad_count)
        :ok
      end
    end
  end

  defp directories(root) do
    case File.ls(root) do
      {:error, :enoent} -> {:ok, []}
      result -> result
    end
  end

  defp load_names(root, names) do
    names
    |> Enum.filter(&Regex.match?(~r/\Aconv_[a-z2-7]{26}\z/, &1))
    |> Enum.reduce(0, fn name, bad_count ->
      if load_name(root, name), do: bad_count, else: bad_count + 1
    end)
  end

  defp load_name(root, name) do
    dir = Path.join(root, name)

    with :ok <- StoreFiles.check(dir),
         {:ok, bytes} <- File.read(Path.join(dir, "subject.json")),
         {:ok, subject} <- Jason.decode(bytes),
         :ok <- index_subject(dir, subject) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp index_subject(_dir, %{"v" => 1, "kind" => "executor"}), do: :ok

  defp index_subject(dir, %{"v" => 1, "kind" => "worker"} = subject) do
    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      reason: nil,
      owner: subject["owner"],
      repository: subject["repository"],
      identifier: subject["identifier"],
      provider_id: subject["provider_id"]
    }

    with {:ok, ref} <- Ref.worker(identity),
         true <- Ref.conversation_id(ref) == subject["conversation_id"] and Path.basename(dir) == subject["conversation_id"] do
      put(dir, ref)
    else
      _ -> {:error, :invalid_subject}
    end
  end

  defp index_subject(_dir, _subject), do: {:error, :invalid_subject}

  defp log_bad_count(count) when count > 0 do
    Logger.warning("Conversation subject index skipped #{count} unreadable subject.json file(s)")
    alert_bad_count(count)
  end

  defp log_bad_count(_count), do: :ok

  defp alert_bad_count(count) do
    emit = Application.get_env(:aiur, :conversation_subject_index_alert_fun, &Aiur.Alerts.emit_system/2)
    message = "Skipped #{count} unreadable conversation subject.json file(s)"
    emit.(@unreadable_subject_topic, message: message, reason: message, needs_attention: true, severity: "warning")
  end
end
