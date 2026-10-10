defmodule Aiur.TestSupport.GithubWebhookReceiverCase do
  @moduledoc false
  # The endpoint boot and request builders shared by the suites split out of
  # `aiur_web/github_webhook_test.exs`.
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Plug.Conn
  import Plug.Test

  alias AiurWeb.GithubWebhook
  alias AiurWeb.GithubWebhook.Auth

  @secret_env "AIUR_GITHUB_WEBHOOK_SECRET"
  @secret "s3cr3t-webhook-token"

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import Plug.Conn
      import Plug.Test
      import Aiur.TestSupport.GithubWebhookReceiverCase

      setup :receiver_setup
    end
  end

  def receiver_setup(_context) do
    original_secret = System.get_env(@secret_env)
    original_alert_fun = Application.get_env(:aiur, :github_webhook_alert_fun)
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    Application.put_env(
      :aiur,
      AiurWeb.Endpoint,
      Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), dashboard_auth_required: false)
    )

    _endpoint = Aiur.TestSupport.start_owned_endpoint!()

    System.put_env(@secret_env, @secret)
    Auth.reset_alert_throttle()

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
      Auth.reset_alert_throttle()

      if is_nil(original_alert_fun) do
        Application.delete_env(:aiur, :github_webhook_alert_fun)
      else
        Application.put_env(:aiur, :github_webhook_alert_fun, original_alert_fun)
      end

      if is_nil(original_secret) do
        System.delete_env(@secret_env)
      else
        System.put_env(@secret_env, original_secret)
      end
    end)

    :ok
  end

  # GitHub's documented algorithm, written out here rather than delegated to the
  # module under test so the tests cannot agree with a wrong implementation.
  def github_signature(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  def payload_of_exactly(bytes) do
    prefix = ~s({"payload":")
    suffix = ~s("})
    padding = bytes - byte_size(prefix) - byte_size(suffix)

    prefix <> :binary.copy("a", padding) <> suffix
  end

  # Shaped like a real `issues` delivery: the full post-action label list plus
  # the `updated_at` the ordering watermark reads.
  def issue_payload(opts) do
    Jason.encode!(%{
      "action" => "labeled",
      "label" => %{"name" => List.last(Keyword.fetch!(opts, :labels))},
      "repository" => %{"full_name" => "aiur-team/aiur"},
      "issue" => %{
        "number" => 1679,
        "updated_at" => Keyword.fetch!(opts, :updated_at),
        "labels" => Enum.map(Keyword.fetch!(opts, :labels), &%{"name" => &1})
      }
    })
  end

  def signed_delivery(body, delivery_id) do
    body
    |> build_conn(signature: github_signature(@secret, body))
    |> put_req_header("x-github-delivery", delivery_id)
    |> put_req_header("x-github-event", "issues")
    |> call()
  end

  # The admission decision the receiver recorded, read back off the conn the
  # production endpoint returned rather than by calling `Ingest` directly.
  def admit(body, opts) do
    body
    |> signed_delivery(Keyword.fetch!(opts, :delivery))
    |> Map.fetch!(:private)
    |> Map.fetch!(GithubWebhook.admission_key())
  end

  def build_conn(body, opts) do
    conn = :post |> conn(GithubWebhook.path(), body) |> put_req_header("content-type", "application/json")

    case Keyword.fetch!(opts, :signature) do
      nil -> conn
      signature -> put_req_header(conn, "x-hub-signature-256", signature)
    end
  end

  def deliver(body, opts), do: body |> build_conn(opts) |> call()

  def call(conn), do: AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))
end
