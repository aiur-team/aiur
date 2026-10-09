defmodule Aiur.TestSupport.MutationFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Aiur.TestSupport.EventTicket
  alias Aiur.GitHub.{Comments, ResourceStore}
  @repo "owner/repo"
  @author "its-everdred"

  def post_comment(id, body) do
    ticket = ticket_id()

    record(
      fn _request -> {:ok, %{status: 201, body: comment(id, body)}} end,
      fn request_fun -> Comments.create_comment(ticket, body, request_fun: request_fun) end
    )
  end

  # Runs `fun` against a recording stub and answers `{count_fun, result}`. The
  # count is a function rather than a number so a case can ask again *after* a
  # view has re-rendered and prove the render cost nothing.
  def record(responder, fun) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    request_fun = fn request ->
      Agent.update(recorder, &[request | &1])
      responder.(request)
    end

    result = fun.(request_fun)

    # `Aiur.TestSupport.safe_stop/1`, not a `Process.alive?/1` guard around
    # `Agent.stop/1`. The recorder is `start_link`ed from the test process, so
    # ExUnit's `exit(:shutdown)` at the end of the test already kills it over the
    # link; the `on_exit/1` callback runs afterwards in a *different* process, so
    # the guard is a TOCTOU race — it observes the recorder alive, the link then
    # kills it, and `Agent.stop/1` exits with that `:shutdown` instead of the
    # `:normal` it asked for, failing the case in teardown. The window is closed
    # on an idle machine (measured: 3000 of 3000 samples found the recorder
    # already dead) and widens under coverage instrumentation, which is why this
    # only ever showed up in the coverage partitions. `safe_stop/1` catches the
    # exit rather than guarding against it; its own docs name this exact race.
    on_exit(fn -> Aiur.TestSupport.safe_stop(recorder) end)

    {fn -> Agent.get(recorder, &Enum.reverse/1) end, result}
  end

  # A view: it subscribes, and when the store changes it re-renders by reading
  # the store. It never fetches. That is the whole contract this unit buys.
  def start_view(key) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        ResourceStore.subscribe(key)
        send(test, :view_subscribed)

        receive do
          {:github_resource_changed, %{key: ^key}} -> send(test, {:rendered, ResourceStore.data(key)})
        after
          5_000 -> send(test, :view_timed_out)
        end
      end)

    assert_receive :view_subscribed, 2_000
    pid
  end

  # GitHub's own issue object, which is the shape
  # `Aiur.Events.GithubWebhook.Deposit` deposits under `:issue` and therefore the
  # shape anything reading that key is entitled to assume. `updated_at` is part
  # of it: every writer in the system derives its version from that field, so a
  # fixture without one would be testing a body no writer can produce.
  def seed_issue(number, label_names) do
    ResourceStore.put_resource(
      issue_key(number),
      %{
        "number" => number,
        "state" => "open",
        "updated_at" => "2026-08-17T12:00:00Z",
        "labels" => labels(label_names)
      },
      source: :fetch,
      version: "2026-08-17T12:00:00Z"
    )
  end

  def labels(names), do: Enum.map(names, &%{"name" => &1})

  def comment_key(id), do: ResourceStore.key(:issue_comment, "owner", "repo", id)
  def issue_key(number), do: ResourceStore.key(:issue, "owner", "repo", number)

  def close_issue_response(_request) do
    number = ticket_number()

    {:ok,
     %{
       status: 200,
       body: %{"number" => number, "state" => "closed", "updated_at" => "2026-08-17T15:00:00Z"}
     }}
  end

  def review_reply_response(%{body: %{"query" => query}}) do
    if String.contains?(query, "addPullRequestReviewThreadReply") do
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "addPullRequestReviewThreadReply" => %{
               "comment" => %{
                 "id" => "PRRC_node",
                 "databaseId" => 880_001,
                 "body" => "addressed",
                 "createdAt" => "2026-08-17T16:00:00Z",
                 "updatedAt" => "2026-08-17T16:00:00Z",
                 "url" => "https://github.com/owner/repo/pull/7#discussion_r880001",
                 "author" => %{"login" => @author}
               }
             }
           }
         }
       }}
    else
      {:ok, %{status: 200, body: %{"data" => %{"node" => nil}}}}
    end
  end

  def resolve_thread_response(_request) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "resolveReviewThread" => %{
             "thread" => %{"id" => "PRRT_thread", "isResolved" => true, "pullRequest" => %{"number" => 7}}
           }
         }
       }
     }}
  end

  def resolved_thread_delivery do
    ticket = ticket_id()
    fixture_value0 = "aiur/#{ticket}-slug"

    %{
      "action" => "resolved",
      "repository" => %{"full_name" => @repo},
      "pull_request" => %{
        "number" => 7,
        "head" => %{"ref" => fixture_value0, "repo" => %{"full_name" => @repo}}
      },
      "thread" => %{"node_id" => "PRRT_thread", "is_resolved" => true, "updated_at" => "2026-08-17T16:00:00Z"}
    }
  end

  # A whole GitHub issue object at generation `n`, in the shape
  # `Aiur.Events.GithubWebhook.Deposit` deposits: GitHub's own REST object, with
  # `"labels"` as the raw label array.
  def issue_at(n) do
    %{
      "number" => 77,
      "state" => if(n < 100, do: "open", else: "closed"),
      "generation" => n,
      "updated_at" => version_at(n),
      "labels" => labels(["agent:todo"])
    }
  end

  # Zero-padded so the store's lexical version comparison orders these the same
  # way the integer generation does.
  def version_at(n), do: "2026-08-17T12:00:#{String.pad_leading(to_string(n), 3, "0")}Z"

  def labelled_delivery(label) do
    number = ticket_number()

    %{
      "action" => "labeled",
      "repository" => %{"full_name" => @repo},
      "label" => %{"name" => label},
      "issue" => %{"number" => number, "updated_at" => "2026-08-17T13:00:00Z"},
      "sender" => %{"login" => @author}
    }
  end

  def delivery(id, body) do
    number = ticket_number()

    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => number},
      "comment" => comment(id, body),
      "sender" => %{"login" => @author}
    }
  end

  def comment(id, body, updated_at \\ "2026-08-17T12:00:00Z") do
    ticket = ticket_id()
    fixture_value0 = "https://github.com/owner/repo/issues/#{ticket}#issuecomment-#{id}"

    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => fixture_value0,
      "user" => %{"login" => @author}
    }
  end

  def stop_store! do
    pid = Process.whereis(ResourceStore)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("ResourceStore did not stop")
    end
  end

  def restart_store!(path) do
    stop_store!()
    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  def await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  def refute_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> flunk("unexpected publish on #{topic}: #{inspect(event)}")
    after
      200 -> :ok
    end
  end
end
