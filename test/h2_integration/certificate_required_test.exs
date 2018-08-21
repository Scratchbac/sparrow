defmodule H2Integration.CerificateRequiredTest do
  use ExUnit.Case

  alias Helpers.SetupHelper, as: Setup
  alias Sparrow.H2Worker.Request, as: OuterRequest

  @cert_path "priv/ssl/client_cert.pem"
  @key_path "priv/ssl/client_key.pem"
  setup do
    {:ok, _cowboy_pid, cowboys_name} =
      :cowboy_router.compile([
        {":_",
         [
           {"/EchoClientCerificateHandler", Helpers.CowboyHandlers.EchoClientCerificateHandler,
            []}
         ]}
      ])
      |> Setup.start_cowboy_tls(certificate_required: :positive_cerificate_verification)

    on_exit(fn ->
      :cowboy.stop_listener(cowboys_name)
    end)

    {:ok, port: :ranch.get_port(cowboys_name)}
  end

  test "cowboy replies with sent cerificate", context do
    auth = Sparrow.H2Worker.Authentication.CertificateBased.new(@cert_path, @key_path)
    config = Sparrow.H2Worker.Config.new(Setup.server_host(), context[:port], auth)
    headers = Setup.default_headers()
    body = "body"
    worker_spec = Setup.child_spec(args: config, name: :name)
    request = OuterRequest.new(headers, body, "/EchoClientCerificateHandler", 2_000)

    {:ok, worker_pid} = start_supervised(worker_spec, [])
    {:ok, {answer_headers, answer_body}} = Sparrow.H2Worker.send_request(worker_pid, request)

    {:ok, pem_bin} = File.read(@cert_path)

    expected_subject = Helpers.CerificateHelper.get_subject_name_form_not_encoded_cert(pem_bin)

    assert_response_header(answer_headers, {":status", "200"})
    assert expected_subject == answer_body
  end

  test "worker rejects cowboy cerificate", context do
    auth = Sparrow.H2Worker.Authentication.CertificateBased.new(@cert_path, @key_path)

    config =
      Sparrow.H2Worker.Config.new(
        Setup.server_host(),
        context[:port],
        auth,
        [
          {:verify, :verify_peer}
        ],
        10_000
      )

    worker_spec = Setup.child_spec(args: config, name: :worker_name)
    {:error, reason} = start_supervised(worker_spec)
    {actual_reason, _} = reason
    assert {:options, {:cacertfile, []}} == actual_reason
  end

  defp assert_response_header(headers, expected_header) do
    assert Enum.any?(headers, &(&1 == expected_header))
  end
end