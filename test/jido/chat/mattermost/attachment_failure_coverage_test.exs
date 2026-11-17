defmodule Jido.Chat.Mattermost.AttachmentFailureCoverageTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{FileUpload, PostPayload}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  @moduletag capture_log: true

  setup do
    result(:upload_files, {:ok, %{"file_infos" => [%{"id" => "file"}]}})
    result(:send_message, {:ok, %{"id" => "post", "file_ids" => ["file"]}})
    result(:edit_message, {:ok, %{"id" => "post", "file_ids" => ["file"]}})
    :ok
  end

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  test "provider error envelopes retain only neutral reasons and configuration keys" do
    for {input, expected} <- [
          {{:http_error, 503}, {:http_error, 503}},
          {%{reason: {429, "private-provider-body"}, token: "private-token"}, {:http_error, 429}},
          {{:missing_configuration, :max_upload_request_size}, {:missing_configuration, :max_upload_request_size}},
          {{:invalid_configuration, :max_file_size}, {:invalid_configuration, :max_file_size}}
        ] do
      result(:upload_files, {:error, input})
      assert {:error, ^expected} = post([file()])
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "uploaded references and new file sources cannot be mixed" do
    assert {:error, :conflicting_file_sources} = post([file()], uploaded_files: [%{id: "file"}])

    assert {:error, :conflicting_file_sources} =
             Adapter.edit_message(
               "room",
               "post",
               "answer",
               Keyword.merge(opts(), files: [file()], uploaded_files: [%{id: "file"}])
             )

    refute_received {:transport_call, _, _}
  end

  for {fault, reason} <- [exception: :transport_exception, exit: :transport_exit] do
    @fault fault
    @reason reason
    test "upload #{@fault} returns its neutral category without publication" do
      result(:upload_files, fault(@fault))
      assert {:error, @reason} = Adapter.send_file("room", file(), opts())
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end

    test "publication #{@fault} never retries an upload or creates a fallback post" do
      result(:send_message, fault(@fault))
      assert {:error, @reason} = post([file()])
      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :send_message, _}
      refute_received {:transport_call, _, _}
    end

    test "multi-file edit #{@fault} never creates a replacement post" do
      result(:edit_message, fault(@fault))
      result(:upload_files, {:ok, %{"file_infos" => [%{"id" => "one"}, %{"id" => "two"}]}})

      assert {:error, @reason} =
               Adapter.edit_message("room", "post", "Answer", Keyword.put(opts(), :files, [file("one"), file("two")]))

      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :edit_message, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "a retired partial upload result cannot publish an inferred prefix" do
    result(
      :upload_files,
      {:error, {:partial_upload, %{reason: :timeout, uploaded: %{"file_infos" => [%{"id" => "file"}]}}}}
    )

    assert {:error, :attachment_delivery_failed} = post([file()])
    assert_received {:transport_call, :upload_files, _}
    refute_received {:transport_call, _, _}
  end

  test "an unusable sibling rejects the entire selection without text fallback" do
    for invalid <- [
          %FileUpload{data: "bytes"},
          %FileUpload{filename: "remote.txt", url: "https://example.com/file.txt"}
        ] do
      assert {:error, reason} = post([file(), invalid])
      assert reason in [:missing_filename, :unsupported_remote_url]
      refute_received {:transport_call, _, _}
    end
  end

  test "legacy selections containing only oversized files fail before transport dispatch" do
    files = [file("one"), file("two")]

    assert {:error, {:file_too_large, %{filename: "one", size: 2, limit: 1}}} = post(files, max_file_size: 1)
    refute_received {:transport_call, _, _}
  end

  @tag :tmp_dir
  test "directory sources fail preflight without attempting an upload", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_file_source} = Adapter.send_file("room", %FileUpload{path: tmp_dir}, opts())
    refute_received {:transport_call, _, _}
  end

  test "unknown provider errors are always redacted" do
    for callback <- [:upload_files, :send_message] do
      result(callback, {:error, {:provider_error, "private detail"}})
      assert {:error, :attachment_delivery_failed} = post([file()])

      result(
        callback,
        if(callback == :upload_files,
          do: {:ok, %{"file_infos" => [%{"id" => "file"}]}},
          else: {:ok, %{"id" => "post", "file_ids" => ["file"]}}
        )
      )
    end
  end

  test "alternate transport upload response shapes retain confirmed server details" do
    for uploaded <- [%{file_infos: [%{id: "file", name: "server.txt"}]}, [%{id: "file", name: "server.txt"}]] do
      result(:upload_files, {:ok, uploaded})
      assert {:ok, response} = Adapter.send_file("room", file(), opts())
      assert response.metadata.file_ids == ["file"]
      assert response.metadata.filename == "server.txt"
      assert [%{filename: "server.txt"}] = response.metadata.attachments
      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :send_message, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "empty payloads and blank attachment captions preserve the requested message text" do
    assert {:ok, _} = post([])
    assert_received {:transport_call, :send_message, ["room", "Answer", _]}

    payload = PostPayload.new(%{text: "", files: [file()]})
    assert {:ok, _} = Adapter.post_message("room", payload, Keyword.put(opts(), :caption, "Caption"))
    assert_received {:transport_call, :upload_files, _}
    assert_received {:transport_call, :send_message, ["room", "Caption", _]}
    refute_received {:transport_call, _, _}
  end

  defp post(files, extra \\ []),
    do: Adapter.post_message("room", PostPayload.new(%{text: "Answer", files: files}), Keyword.merge(opts(), extra))

  defp file(name \\ "file.txt"), do: %FileUpload{filename: name, data: "ok", media_type: "text/plain"}
  defp opts, do: [transport: RecordingTransport, max_file_size: 1000]
  defp result(callback, value), do: Process.put({RecordingTransport, callback}, value)
  defp fault(:exception), do: fn -> raise "transport unavailable" end
  defp fault(:exit), do: fn -> exit(:transport_unavailable) end
end
