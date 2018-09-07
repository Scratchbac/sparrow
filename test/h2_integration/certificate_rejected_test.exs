defmodule H2Integration.CerificateRejectedTest do
  use ExUnit.Case

  alias Helpers.SetupHelper, as: Setup

  setup_all do
    {:ok, _cowboy_pid, cowboys_name} =
      [
        {":_",
         [
           {"/RejectCertificateHandler",
            Helpers.CowboyHandlers.RejectCertificateHandler, []}
         ]}
      ]
      |> :cowboy_router.compile()
      |> Setup.start_cowboy_tls(
        certificate_required: :negative_cerificate_verification
      )

    on_exit(fn ->
      :cowboy.stop_listener(cowboys_name)
    end)

    {:ok, port: :ranch.get_port(cowboys_name)}
  end

  test "cowboy does not accept certificate", context do
    config = Setup.create_h2_worker_config(Setup.server_host(), context[:port])

    worker_spec = Setup.child_spec(args: config, name: :name)

    {:error, reason} = start_supervised(worker_spec, [])
    {{_, {_, _, {_, {_, _, actual_reason}}}}, _} = reason
    assert {:tls_alert, 'bad certificate'} == actual_reason
  end
end
