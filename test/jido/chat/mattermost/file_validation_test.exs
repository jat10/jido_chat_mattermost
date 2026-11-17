defmodule Jido.Chat.Mattermost.FileValidationTest do
  use ExUnit.Case, async: true

  test "optional primitives reject missing callbacks and empty candidates without side effects" do
    alias Jido.Chat.Mattermost.Test.RecordingTransport
    opts = [transport: __MODULE__, max_file_size: 100]

    assert {:error, :unsupported} =
             Jido.Chat.Mattermost.Adapter.prepare_upload("room", [%{data: "x", filename: "file"}], opts)

    prepared = %{
      channel_id: "room",
      body: "x",
      content_type: "multipart/form-data",
      size_bytes: 1,
      files: [%{filename: "file"}]
    }

    assert {:error, :unsupported} = Jido.Chat.Mattermost.Adapter.upload_prepared(prepared, opts)

    for files <- [[], nil] do
      assert {:error, :invalid_files} =
               Jido.Chat.Mattermost.Adapter.prepare_upload("room", files,
                 transport: RecordingTransport,
                 max_file_size: 100
               )
    end

    refute_received {:transport_call, _, _}
  end

  test "provider requirements expose independent configuration without I/O" do
    assert {:ok, %{max_file_size: 123, max_files_per_post: 10, max_upload_request_size: :unresolved}} =
             Jido.Chat.Mattermost.Adapter.file_requirements(max_file_size: 123, max_upload_request_size: nil)

    assert {:ok, %{max_file_size: :unresolved, max_upload_request_size: 456}} =
             Jido.Chat.Mattermost.Adapter.file_requirements(max_file_size: nil, max_upload_request_size: 456)

    for key <- [:max_file_size, :max_upload_request_size] do
      assert {:error, {:invalid_configuration, ^key}} = Jido.Chat.Mattermost.Adapter.file_requirements([{key, 0}])
    end
  end

  test "provider prepares bytes without credentials or reading paths" do
    opts = [max_file_size: 100, max_upload_request_size: 2048]

    assert {:ok, prepared} =
             Jido.Chat.Mattermost.Adapter.prepare_upload("room", [%{data: "bytes", filename: "file.txt"}], opts)

    assert prepared.size_bytes == byte_size(prepared.body)
    assert prepared.body =~ "bytes"

    assert {:error, :file_not_materialized} =
             Jido.Chat.Mattermost.Adapter.prepare_upload(
               "room",
               [%{path: "/does/not/exist", filename: "missing"}],
               opts
             )

    assert {:error, {:file_too_large, %{size: 101, limit: 100}}} =
             Jido.Chat.Mattermost.Adapter.prepare_upload(
               "room",
               [%{data: String.duplicate("x", 101), filename: "large"}],
               opts
             )
  end

  test "provider upload primitive confirms complete identities before returning references" do
    alias Jido.Chat.Mattermost.Test.RecordingTransport

    prepared = %{
      channel_id: "room",
      body: "encoded",
      content_type: "multipart/form-data; boundary=x",
      size_bytes: 7,
      files: [%{filename: "input.txt", content_type: "text/plain", size_bytes: 2}]
    }

    opts = [transport: RecordingTransport]

    for result <- [{:ok, %{"file_infos" => []}}, {:ok, %{"file_infos" => [%{"name" => "input.txt"}]}}] do
      Process.put({RecordingTransport, :upload_prepared}, result)
      assert {:error, _} = Jido.Chat.Mattermost.Adapter.upload_prepared(prepared, opts)
      assert_received {:transport_call, :upload_prepared, [^prepared, _]}
    end

    Process.put({RecordingTransport, :upload_prepared}, {:ok, %{"file_infos" => [%{"id" => "provider-id"}]}})

    assert {:ok, %{files: [%{id: "provider-id", filename: "input.txt", size_bytes: 2}]}} =
             Jido.Chat.Mattermost.Adapter.upload_prepared(prepared, opts)

    assert_received {:transport_call, :upload_prepared, [^prepared, _]}
    assert {:error, :invalid_prepared_upload} = Jido.Chat.Mattermost.Adapter.upload_prepared(%{}, opts)
    refute_received {:transport_call, _, _}
  end

  alias Jido.Chat.Mattermost.Adapter

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  test "validates lazy metadata without touching content, paths or transport" do
    files = [
      %{name: "empty.txt", size: 0, path: "/does/not/exist"},
      %{"filename" => "limit.txt", "metadata" => %{"size" => 10}},
      %{name: "nested.txt", metadata: %{size: 1}, content: nil}
    ]

    assert :ok = Adapter.validate_files(files, max_file_size: 10, transport: MustNotBeCalled)
  end

  test "returns the oversized file to the caller before any upload" do
    files = [%{name: "ok", size: 10}, %{name: "large", size: 11}]

    assert {:error, {:file_too_large, %{filename: "large", size: 11, limit: 10}}} =
             Adapter.validate_files(files, max_file_size: 10)
  end

  test "rejects missing or invalid sizes and malformed batches" do
    for size <- [nil, -1, "10", 1.5] do
      assert {:error, {:invalid_file_size, %{filename: "file"}}} =
               Adapter.validate_files([%{name: "file", size: size}], max_file_size: 10)
    end

    assert {:error, :invalid_file_metadata} = Adapter.validate_files([nil], max_file_size: 10)
    assert {:error, :invalid_files} = Adapter.validate_files(nil, max_file_size: 10)
  end

  test "requires valid configuration only for nonempty batches" do
    assert :ok = Adapter.validate_files([], max_file_size: nil)

    assert {:error, {:missing_configuration, :max_file_size}} =
             Adapter.validate_files([%{size: 1}], max_file_size: nil)

    for limit <- [0, -1, "10"] do
      assert {:error, {:invalid_configuration, :max_file_size}} =
               Adapter.validate_files([%{size: 1}], max_file_size: limit)
    end
  end
end
