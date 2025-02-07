defmodule Sparrow do
  @moduledoc """
  Sparrow is service providing ability to send push
  notification to `FCM` (Firebase Cloud Messaging) and/or
  `APNS` (Apple Push Notification Service).
  """
  use Application

  def start(_type, _args) do
    raw_fcm_config = Application.get_env(:sparrow, :fcm)
    raw_apns_config = Application.get_env(:sparrow, :apns)
    pool_enabled = Application.get_env(:sparrow, :pool_enabled, false)
    start({raw_fcm_config, raw_apns_config, pool_enabled})
  end

  @spec start({Keyword.t(), Keyword.t(), boolean()}) :: Supervisor.on_start()
  def start({raw_fcm_config, raw_apns_config, is_enabled}) do
    children =
      is_enabled
      |> maybe_start_pools_warden()
      |> maybe_append({Sparrow.FCM.V1.Supervisor, raw_fcm_config})
      |> maybe_append({Sparrow.APNS.Supervisor, raw_apns_config})

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  @spec maybe_append([any], {any, nil | list}) :: [any]
  defp maybe_append(list, {_, nil}), do: list
  defp maybe_append(list, elem), do: list ++ [elem]

  defp maybe_start_pools_warden(true), do: [Sparrow.PoolsWarden]
  defp maybe_start_pools_warden(false), do: []
end
