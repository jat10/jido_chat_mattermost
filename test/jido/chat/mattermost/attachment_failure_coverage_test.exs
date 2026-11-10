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

  test "continue skips a failed continuation upload and retains the confirmed first post" do
    ids = Enum.map(1..10, &"file-#{&1}")

    result(:upload_files, fn ->
      case Process.get(:upload_count, 0) do
        0 ->
          Process.put(:upload_count, 1)
          {:ok, %{"file_infos" => Enum.map(ids, &%{"id" => &1})}}

        1 ->
          {:error, :timeout}
      end
    end)

    result(:send_message, {:ok, %{"id" => "post", "file_ids" => ids}})
    files = Enum.map(1..11, &file("#{&1}.txt"))

    assert {:ok, response} = post(files, attachment_failure_policy: :continue)
    report = response.metadata.delivery_report
    assert report.confirmation == :partial
    assert [%{message_id: "post", delivery_part_index: 0}] = report.messages
    assert [%{filename: "11.txt", reason: :timeout, stage: :upload, delivery: :not_sent}] = report.failed_files
    assert Enum.map(report.uploaded_files, & &1.file_id) == ids
    assert_received {:transport_call, :upload_files, ["room", first, _]}
    assert length(first) == 10
    assert_received {:transport_call, :upload_files, ["room", [%{filename: "11.txt"}], _]}
    assert_received {:transport_call, :send_message, ["room", "Answer", _]}
    refute_received {:transport_call, _, _}
  end

  for {fault, reason} <- [exception: :transport_exception, exit: :transport_exit] do
    @fault fault
    @reason reason

    test "strict uploads convert #{@fault} into a failure without publication" do
      result(:upload_files, fault(@fault))

      assert {:error, {:attachment_delivery_failed, report}} =
               post([file()], attachment_failure_policy: :abort)

      assert report.delivery == :not_sent
      assert report.messages == []
      assert report.uploaded_files == []
      assert [%{filename: "file.txt", reason: @reason, stage: :upload, delivery: :not_sent}] = report.failed_files
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end

    test "policy publication #{@fault} reports the existing upload as unconfirmed without retry" do
      result(:send_message, fault(@fault))

      assert {:error, {:attachment_delivery_failed, report}} =
               post([file()], attachment_failure_policy: :continue)

      assert report.delivery == :unconfirmed
      assert report.messages == []
      assert [%{filename: "file.txt", file_id: "file"}] = report.uploaded_files
      assert [%{reason: @reason, stage: :transport, delivery: :unconfirmed}] = report.failed_files
      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :send_message, _}
      refute_received {:transport_call, _, _}
    end

    test "legacy upload #{@fault} returns its category without publishing" do
      result(:upload_files, fault(@fault))
      assert {:error, @reason} = Adapter.send_file("room", file(), opts())
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end

    test "legacy multi-file edit #{@fault} never creates a replacement post" do
      result(:edit_message, fault(@fault))
      result(:upload_files, {:ok, %{"file_infos" => [%{"id" => "one"}, %{"id" => "two"}]}})

      assert {:error, @reason} =
               Adapter.edit_message("room", "post", "Answer", Keyword.put(opts(), :files, [file("one"), file("two")]))

      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :edit_message, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "empty partial upload prefixes retain the original failure without publication" do
    result(:upload_files, {:error, {:partial_upload, %{reason: :timeout, uploaded: %{"file_infos" => []}}}})

    assert {:error, {:attachment_delivery_failed, report}} = post([file()], attachment_failure_policy: :abort)
    assert report.delivery == :not_sent
    assert report.uploaded_files == []
    assert [%{reason: :timeout, stage: :upload}] = report.failed_files
    assert_received {:transport_call, :upload_files, _}
    refute_received {:transport_call, _, _}
  end

  test "invalid partial upload prefixes are rejected as unconfirmed before publication" do
    for infos <- [
          [%{"id" => "one"}, %{"id" => "extra"}],
          [%{"name" => "missing-id.txt"}],
          [%{"id" => ""}]
        ] do
      result(:upload_files, {:error, {:partial_upload, %{reason: :timeout, uploaded: %{"file_infos" => infos}}}})

      assert {:error, {:attachment_delivery_failed, report}} = post([file()], attachment_failure_policy: :abort)
      assert report.delivery == :not_sent
      assert report.uploaded_files == []
      assert [%{reason: :unconfirmed_upload, stage: :upload}] = report.failed_files
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "continue rejects unusable file sources individually and publishes the valid file once" do
    files = [
      %FileUpload{data: "bytes"},
      %FileUpload{filename: "remote.txt", url: "https://example.com/file.txt"},
      file()
    ]

    assert {:ok, response} = post(files, attachment_failure_policy: :continue)
    assert response.metadata.file_ids == ["file"]

    assert [
             %{reason: :missing_filename, delivery: :not_sent},
             %{filename: "remote.txt", reason: :unsupported_remote_url, delivery: :not_sent}
           ] = response.metadata.delivery_report.failed_files

    assert_received {:transport_call, :upload_files, ["room", [%{filename: "file.txt"}], _]}
    assert_received {:transport_call, :send_message, _}
    refute_received {:transport_call, _, _}
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

  test "unknown provider errors are redacted in policy reports" do
    result(:upload_files, {:error, {:provider_error, "private detail"}})

    assert {:error, {:attachment_delivery_failed, report}} = post([file()], attachment_failure_policy: :abort)
    assert [%{reason: :attachment_delivery_failed}] = report.failed_files
    refute inspect(report) =~ "private detail"
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
