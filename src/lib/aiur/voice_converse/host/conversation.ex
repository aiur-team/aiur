defmodule Aiur.VoiceConverse.Host.Conversation do
  @moduledoc false
  alias Aiur.Conversation.{History, Ref}
  alias Aiur.LiveConversation
  alias Aiur.VoiceConverse.Host.Worker

  @spec read(Worker.t(), keyword()) :: {:ok, String.t()} | {:error, :unavailable}
  def read(%Worker{identity: identity} = target, opts) do
    history = Keyword.get(opts, :history, History)
    limit = opts |> Keyword.get(:n, 20) |> max(1) |> min(200)

    with {:ok, ref} <- Ref.worker(identity) do
      if history && Code.ensure_loaded?(history) && function_exported?(history, :list_entries, 2) do
        journal(history.list_entries(ref, principal: :internal, tail: true, limit: limit))
      else
        live(target, limit, opts)
      end
    else
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp journal({:ok, page}) do
    complete = page.complete_from_start and is_nil(page.prev_cursor)
    {:ok, render(page.entries, "journal", complete)}
  end

  defp journal(_error), do: {:error, :unavailable}

  defp live(%Worker{live_source: nil}, _limit, _opts), do: {:error, :unavailable}

  defp live(%Worker{live_source: source}, limit, opts) do
    live = Keyword.get(opts, :live, LiveConversation)

    case live.snapshot(source, Keyword.take(opts, [:server])) do
      %{state: state, messages: messages} when state in [:live, :ended, :known_empty, :stale] ->
        {:ok, render(Enum.take(messages, -limit), "live", false)}

      _ ->
        {:error, :unavailable}
    end
  end

  defp render(entries, source, complete) do
    header = "Conversation source: #{source}; complete: #{complete}."
    lines = Enum.map_join(entries, "\n", &"#{&1.role}: #{&1.body}")
    header <> "\n" <> if(lines == "", do: "No retained messages.", else: lines)
  end
end
