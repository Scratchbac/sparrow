defmodule Sparrow.FCM.V1 do
  @moduledoc """
  Provides functions to build and send push notifications to FCM v1.
  """
  use Sparrow.Telemetry.Timer
  require Logger

  alias Sparrow.H2Worker.Request

  @type reason :: atom
  @type headers :: Request.headers()
  @type body :: String.t()
  @type push_opts :: [{:is_sync, boolean()} | {:timeout, non_neg_integer}]
  @type android :: Sparrow.FCM.V1.Notification.android()
  @type webpush :: Sparrow.FCM.V1.Notification.webpush()
  @type apns :: Sparrow.FCM.V1.Notification.apns()
  @type authentication :: Sparrow.H2Worker.Config.authentication()
  @type tls_options :: Sparrow.H2Worker.Config.tls_options()
  @type time_in_miliseconds :: Sparrow.H2Worker.Config.time_in_miliseconds()
  @type http_status :: non_neg_integer
  @type sync_push_result ::
          {:error, :connection_lost}
          | {:ok, {headers, body}}
          | {:error, :request_timeout}
          | {:error, :not_ready}
          | {:error, :invalid_notification}
          | {:error, reason}

  @doc """
    Sends the push notification to FCM v1.

  ## Options

  * `:is_sync` - Determines whether the worker should wait for response after sending the request. When set to `true` (default), the result of calling this functions is one of:
      * `:ok` when the response is received.
      * `{:error, :request_timeout}` when the response doesn't arrive until timeout occurs (see the `:timeout` option).
      * `{:error, :connection_lost}` when the connection to FCM is lost before the response arrives.
      * `{:error, :not_ready}` when stream response is not yet ready, but it h2worker tries to get it.
      * `{:error, :invalid_notification}` when notification does not contain neither title nor body.
      * `{:error, :reason}` when error with other reason occures.
    * `:timeout` - Request timeout in milliseconds. Defaults value is 5000.
  """
  @timed event_tags: [:push, :fcm]
  @spec push(
          atom,
    Sparrow.FCM.V1.Notification.t(),
    push_opts
  ) :: sync_push_result | :ok
  def push(h2_worker_pool, maybe_batch_notification, opts) do
    extract_batch_notification(h2_worker_pool, maybe_batch_notification, opts)
  end

  def push(h2_worker_pool, notification),
    do: push(h2_worker_pool, notification, [])

  defp extract_batch_notification(_wpoll, [], _options), do: :ok
  defp extract_batch_notification(wpoll, [head | rest] = _notifications, opts) do
    options = Keyword.put_new(opts, :is_sync, false)
    case extract_batch_notification(wpoll, head, options) do
      {:error, reason} ->
        _ = Logger.info("Error while sending notification",
          what: :result_push_notif,
          action: :next_notification_if_any,
          reason: reason,
          request: head)
        extract_batch_notification(wpoll, rest, options)
      _ -> extract_batch_notification(wpoll, rest, options)
    end
  end
  defp extract_batch_notification(_wpoll, %{target: []}, _options), do: :ok
  defp extract_batch_notification(wpoll, %{target: [token | rest]} = notification, opts) do
    options = Keyword.put_new(opts, :is_sync, false)
    case extract_batch_notification(wpoll, %{notification | target: token}, options) do
      {:error, reason} ->
        _ = Logger.info("Error while sending notification",
          what: :result_push_notif,
          action: :next_notification_if_any,
          reason: reason,
          request: notification)
        extract_batch_notification(wpoll, %{notification | target: rest}, options)
      _ -> extract_batch_notification(wpoll, %{notification | target: rest}, options)
    end
  end

  defp extract_batch_notification(wpoll, notification, options) do
    case Sparrow.FCM.V1.Notification.normalize(notification) do
      {:error, reason} -> {:error, reason}

      {:ok, notification} -> do_push(wpoll, notification, options)
    end
  end

  @spec do_push(
          atom,
          Sparrow.FCM.V1.Notification.t(),
          push_opts
        ) :: sync_push_result | :ok
  def do_push(h2_worker_pool, notification, opts) do
    # Prep FCM's ProjectId
    project_id = Sparrow.FCM.V1.ProjectIdBearer.get_project_id(h2_worker_pool)

    notification =
      Sparrow.FCM.V1.Notification.add_project_id(notification, project_id)

    is_sync = Keyword.get(opts, :is_sync, true)
    timeout = Keyword.get(opts, :timeout, 30_000)
    strategy = Keyword.get(opts, :strategy, :random_worker)
    headers = notification.headers
    json_body = notification |> make_body() |> Jason.encode!()
    path = path(notification.project_id)
    request = Request.new(headers, json_body, path, timeout)

    _ =
      Logger.debug("Sending FCM notification",
        what: :push_fcm_notification,
        request: request
      )

    h2_worker_pool
    |> Sparrow.H2Worker.Pool.send_request(
      request,
      is_sync,
      timeout,
      strategy
    )
    |> process_response()
  end

  @spec process_response(:ok | {:ok, {headers, body}} | {:error, reason}) ::
          :ok
          | {:error, reason :: :request_timeout | :not_ready | reason}

  def process_response(:ok) do
    _ =
      Logger.debug("Processing async FCM notification response",
        what: :async_fcm_push_response
      )

    :ok
  end

  def process_response({:ok, {_headers, body}}) when is_list(body) do
    Enum.map(body, fn %{"headers" => headers, "body" => body} ->
      process_response({:ok, {headers, body}})
    end)
  end

  def process_response({:ok, {headers, body}}) do
    _ =
      Logger.debug("Processing FCM notification response",
        what: :fcm_push_response,
        raw: inspect({:ok, {headers, body}})
      )

    if {":status", "200"} in headers do
      _ =
        Logger.debug("Processing FCM notification response",
          what: :fcm_push_response,
          result: :success,
          status: "200"
        )

      :ok
    else
      status = get_status_from_headers(headers)

      _ =
        Logger.debug("Processing FCM notification response",
          what: :fcm_push_response,
          result: :error,
          status: inspect(status)
        )

      reason =
        body
        |> get_reason_from_body()
        |> String.to_atom()

      _ =
        Logger.warning("Processing FCM notification response",
          what: :fcm_push_response,
          result: :error,
          response_body: inspect(body)
        )

      {:error, reason}
    end
  end

  def process_response({:error, reason}), do: {:error, reason}

  @doc """
  Function providing `Sparrow.H2Worker.Authentication.TokenBased` for FCM pools.
  Requres `Sparrow.FCM.TokenBearer` to be started.
  """
  @spec get_token_based_authentication(String.t()) ::
          Sparrow.H2Worker.Authentication.TokenBased.t()
  def get_token_based_authentication(account) do
    getter = fn ->
      {"authorization",
       "Bearer #{Sparrow.FCM.V1.TokenBearer.get_token(account)}"}
    end

    Sparrow.H2Worker.Authentication.TokenBased.new(getter)
  end

  @doc """
  Function providing `Sparrow.H2Worker.Config` for FCM pools.

  ## Example

  # Token based authentication:
    config =
      Sparrow.FCM.V1.get_token_based_authentication()
      |> Sparrow.FCM.V1.get_h2worker_config()

  """
  @spec get_h2worker_config(
          authentication,
          String.t(),
          pos_integer,
          tls_options,
          time_in_miliseconds,
          pos_integer
        ) :: Sparrow.H2Worker.Config.t()
  def get_h2worker_config(
        authentication,
        uri \\ "fcm.googleapis.com",
        port \\ 443,
        tls_opts \\ [],
        ping_interval \\ 5000,
        reconnect_attempts \\ 3
      ) do
    Sparrow.H2Worker.Config.new(%{
      domain: uri,
      port: port,
      authentication: authentication,
      tls_options: tls_opts,
      ping_interval: ping_interval,
      reconnect_attempts: reconnect_attempts,
      pool_type: :fcm
    })
  end

  @spec make_body(Sparrow.FCM.V1.Notification.t()) :: map
  defp make_body(notification) do
    message =
      %{
        :data => notification.data,
        :notification => build_notification(notification),
        notification.target_type => notification.target
      }
      |> maybe_add_android(notification.android)
      |> maybe_add_webpush(notification.webpush)
      |> maybe_add_apns(notification.apns)

    %{message: message}
  end

  @spec build_notification(Sparrow.FCM.V1.Notification.t()) :: map
  defp build_notification(notification) do
    maybe_title =
      if notification.title != nil do
        %{:title => notification.title}
      else
        %{}
      end

    maybe_body =
      if notification.body != nil do
        %{:body => notification.body}
      else
        %{}
      end

    Map.merge(maybe_title, maybe_body)
  end

  @spec maybe_add_android(map, android) :: map
  defp maybe_add_android(body, nil) do
    body
  end

  defp maybe_add_android(body, android) do
    Map.put(body, :android, Sparrow.FCM.V1.Android.to_map(android))
  end

  @spec maybe_add_webpush(map, webpush) :: map
  defp maybe_add_webpush(body, nil) do
    body
  end

  defp maybe_add_webpush(body, webpush) do
    Map.put(body, :webpush, Sparrow.FCM.V1.Webpush.to_map(webpush))
  end

  @spec maybe_add_apns(map, apns) :: map
  defp maybe_add_apns(body, nil) do
    body
  end

  defp maybe_add_apns(body, apns) do
    Map.put(body, :apns, Sparrow.FCM.V1.APNS.to_map(apns))
  end

  @spec path(String.t()) :: String.t()
  defp path(project_id) do
    "/v1/projects/#{project_id}/messages:send"
  end

  @spec get_status_from_headers(headers) :: http_status
  defp get_status_from_headers(headers) do
    {_, status} = List.keyfind(headers, ":status", 0)
    {result, _} = Integer.parse(status)
    result
  end

  @spec get_reason_from_body(String.t()) :: String.t() | nil
  defp get_reason_from_body(body) when is_bitstring(body) do
    body
    |> Jason.decode!()
    |> get_reason_from_body()
  end
  defp get_reason_from_body(%{"error" =>%{"details" => [%{"@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode" => ec} | _]}}) do
    ec
  end

  defp get_reason_from_body(%{"error" => %{"details" => [_ | tl]}}) do
    get_reason_from_body(%{"error" => %{"details" => tl}})
  end

  defp get_reason_from_body(%{"error" =>%{"status" => status}}) when is_binary(status) do
    status
  end
  defp get_reason_from_body(_), do: "UNKNOWN_ERROR"

  def subscription(h2_worker_pool, subscription, opts) do
    is_sync = Keyword.get(opts, :is_sync, true)
    timeout = Keyword.get(opts, :timeout, 30_000)
    strategy = Keyword.get(opts, :strategy, :random_worker)
    json_body = Sparrow.FCM.V1.Subscription.body(subscription)
    path = Sparrow.FCM.V1.Subscription.path(subscription)
    headers = [
      {"content-type", "application/json"}
    ]
    request = Request.new(headers, json_body, path, timeout)

    _ =
      Logger.debug("Sending FCM subscription",
        what: :push_fcm_notification,
        request: request
      )

    h2_worker_pool
    |> Sparrow.H2Worker.Pool.send_request(
      {:subscription, request},
      is_sync,
      timeout,
      strategy
    )
    |> process_subscription_response()
  end

  defp process_subscription_response({:ok, {headers, body}}) do
    if {":status", "200"} in headers do
      _ =
        Logger.debug("Processing FCM subscription response",
          what: :fcm_subscription_response,
          result: :success,
          status: "200"
        )
      _ =
        Logger.info("Subscription response",
          what: :fcm_subscription_response,
          result: :success,
          status: "200",
          data: inspect body
        )

      :ok
    else
      status = get_status_from_headers(headers)

      _ =
        Logger.debug("Processing FCM subscription response",
          what: :fcm_push_response,
          result: :error,
          status: inspect(status)
        )

      reason =
        body
        |> get_reason_from_body()
        |> String.to_atom()

      _ =
        Logger.warning("Processing FCM subscription response",
          what: :fcm_push_response,
          result: :error,
          response_body: inspect(body)
        )

      {:error, reason}
    end
  end
  defp process_subscription_response({:error, _reason} = err), do: err
end
