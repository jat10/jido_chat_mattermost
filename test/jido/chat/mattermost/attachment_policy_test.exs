defmodule Jido.Chat.Mattermost.AttachmentPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jido.Chat.{FileUpload, Postable, Thread}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.PolicyTransport

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
    assert Jido.Chat.Adapter.capabilities(Adapter).attachment_failure_policy == :native
  end

  test "strict policy uploads every group before the first publication and uploads once" do
    files = Enum.map(1..11, &file("#{&1}.txt"))
    assert {:ok, response} = post(files, :abort)
    assert response.response.metadata.delivery_report.confirmation == :confirmed
    assert {:upload, first, _} = next_call()
    assert length(first) == 10
    assert {:upload, ["11.txt"], _} = next_call()
    assert {:publish, :send, nil, "Answer", first_opts} = next_call()
    assert first_opts[:file_ids] == first
    assert {:publish, :send, nil, "Additional files (2/2).", second_opts} = next_call()
    assert second_opts[:thread_id] == "post-1"
    refute_received {:upload, _, _}
  end

  test "strict later-group upload failure prevents every final post" do
    files = Enum.map(1..10, &file("#{&1}.txt")) ++ [file("fail.txt")]
    assert {:error, {:attachment_delivery_failed, report}} = post(files, :abort)
    assert report.messages == []
    assert report.delivery == :not_sent
    assert length(report.uploaded_files) == 10
    refute_received {:publish, _, _, _, _}
  end

  test "strict attachment edit cannot update a placeholder after a later upload failure" do
    files = Enum.map(1..10, &file("#{&1}.txt")) ++ [file("fail.txt")]
    opts = Keyword.put(opts(:abort), :files, files)
    assert {:error, {:attachment_delivery_failed, _}} = Adapter.edit_message("room", "placeholder", "Answer", opts)
    refute_received {:publish, _, _, _, _}
  end

  test "continue keeps valid files after preflight rejection and reports only published files" do
    assert {:ok, sent} = post([file("large.txt", "too big"), file("ok.txt")], :continue, max_file_size: 3)
    assert sent.response.metadata.file_ids == ["ok.txt"]

    assert [%{filename: "large.txt", reason: :file_too_large, size: 7, limit: 3, delivery: :not_sent}] =
             sent.response.metadata.delivery_report.failed_files

    assert_received {:upload, ["ok.txt"], _}
    assert_received {:publish, :send, nil, "Answer", publish_opts}
    assert publish_opts[:file_ids] == ["ok.txt"]
  end

  test "strict preflight rejection performs no upload or publication" do
    assert {:error, {:attachment_delivery_failed, _}} =
             post([file("large.txt", "too big"), file("ok.txt")], :abort, max_file_size: 3)

    refute_received {:upload, _, _}
    refute_received {:publish, _, _, _, _}
  end

  test "continue reuses a confirmed upload prefix after a later HTTP batch fails" do
    assert {:ok, sent} = post([file("ok.txt"), file("partial.txt")], :continue)
    report = sent.response.metadata.delivery_report
    assert [%{filename: "ok.txt", file_id: "ok.txt"}] = report.uploaded_files
    assert [%{filename: "partial.txt", delivery: :not_sent}] = report.failed_files
    assert sent.response.metadata.file_ids == ["ok.txt"]
    assert {:upload, ["ok.txt", "partial.txt"], _} = next_call()
    assert {:publish, :send, nil, "Answer", publish_opts} = next_call()
    assert publish_opts[:file_ids] == ["ok.txt"]
    refute_received {:upload, _, _}
  end

  test "strict reports a confirmed upload prefix but publishes none after a later batch fails" do
    assert {:error, {:attachment_delivery_failed, report}} = post([file("ok.txt"), file("partial.txt")], :abort)
    assert [%{filename: "ok.txt", file_id: "ok.txt"}] = report.uploaded_files
    assert report.messages == []
    refute_received {:publish, _, _, _, _}
  end

  test "continue publishes text once after all uploads fail" do
    assert {:ok, sent} = post([file("fail.txt")], :continue)
    assert sent.response.metadata.delivery_report.confirmation == :partial
    assert_received {:upload, ["fail.txt"], _}
    assert_received {:publish, :send, nil, "Answer", publish_opts}
    assert publish_opts[:file_ids] in [nil, []]
    refute_received {:publish, _, _, _, _}
  end

  test "continue publishes text once when all files are rejected before upload" do
    assert {:ok, sent} = post([file("large.txt", "too big")], :continue, max_file_size: 3)
    assert sent.response.metadata.attachments == []
    assert sent.response.metadata.delivery_report.confirmation == :partial
    assert [%{filename: "large.txt"}] = sent.response.metadata.delivery_report.failed_files
    assert_received {:publish, :send, nil, "Answer", _}
    refute_received {:upload, _, _}
    refute_received {:publish, _, _, _, _}
  end

  test "failed final send and edit are unconfirmed and never replaced" do
    for action <- [:send, :edit] do
      Process.put({PolicyTransport, :publications}, 0)
      Process.put({PolicyTransport, :fail_publication}, 1)

      result =
        if action == :send,
          do: post([file("ok.txt")], :continue),
          else:
            Adapter.edit_message(
              "room",
              "placeholder",
              "Answer",
              Keyword.put(opts(:continue), :files, [file("ok.txt")])
            )

      assert {:error, {:attachment_delivery_failed, report}} = result
      assert report.delivery == :unconfirmed
      assert report.messages == []
      assert [%{filename: "ok.txt", delivery: :unconfirmed}] = report.failed_files
      assert_received {:upload, ["ok.txt"], _}
      assert_received {:publish, ^action, _, "Answer", _}
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}
    end
  end

  test "strict publication failure retains earlier posts without retry or rollback claim" do
    Process.put({PolicyTransport, :fail_publication}, 2)
    files = Enum.map(1..11, &file("#{&1}.txt"))
    assert {:ok, sent} = post(files, :abort)
    report = sent.response.metadata.delivery_report
    assert report.confirmation == :partial
    assert [%{message_id: "post-1"}] = report.messages
    assert [%{filename: "11.txt", delivery: :unconfirmed}] = report.failed_files
    assert length(report.uploaded_files) == 11
    assert_received {:publish, :send, nil, "Answer", _}
    assert_received {:publish, :send, nil, "Additional files (2/2).", _}
    refute_received {:publish, _, _, _, _}
  end

  test "unknown explicit policy fails before effects" do
    assert {:error, {:invalid_attachment_failure_policy, :invalid}} = post([file("ok.txt")], :invalid)
    refute_received {:upload, _, _}
    refute_received {:publish, _, _, _, _}
  end

  test "upload reports normalize equivalent transport errors and retain the successful prefix" do
    for {reason, category} <- transport_errors(), policy <- [:abort, :continue] do
      Process.put({PolicyTransport, :upload_error}, reason)
      Process.put({PolicyTransport, :publications}, 0)

      {result, logs} = with_log(fn -> post([file("ok.txt"), file("partial.txt")], policy) end)

      report =
        if policy == :abort do
          assert {:error, {:attachment_delivery_failed, report}} = result
          assert report.delivery == :not_sent
          assert report.messages == []
          refute_received {:publish, _, _, _, _}
          report
        else
          assert {:ok, sent} = result
          assert_received {:publish, :send, nil, "Answer", publication}
          assert publication[:file_ids] == ["ok.txt"]
          sent.response.metadata.delivery_report
        end

      assert [%{filename: "ok.txt", file_id: "ok.txt"}] = report.uploaded_files
      assert [%{filename: "partial.txt", reason: ^category, stage: :upload, delivery: :not_sent}] = report.failed_files
      assert_received {:upload, ["ok.txt", "partial.txt"], _}
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}
      refute inspect(report) <> logs =~ "private-provider-detail"
      refute inspect(report) <> logs =~ "Req.TransportError"
    end
  end

  test "final send and edit reports normalize errors without retrying publication" do
    for {reason, category} <- transport_errors(), action <- [:send, :edit] do
      Process.put({PolicyTransport, :publication_error}, reason)
      Process.put({PolicyTransport, :publications}, 0)
      Process.put({PolicyTransport, :fail_publication}, 1)

      {result, logs} =
        with_log(fn ->
          if action == :send,
            do: post([file("ok.txt")], :continue),
            else:
              Adapter.edit_message(
                "room",
                "placeholder",
                "Answer",
                Keyword.put(opts(:continue), :files, [file("ok.txt")])
              )
        end)

      assert {:error, {:attachment_delivery_failed, report}} = result
      assert report.delivery == :unconfirmed
      assert report.messages == []
      assert [%{reason: ^category, stage: :transport, delivery: :unconfirmed}] = report.failed_files
      assert [%{filename: "ok.txt", file_id: "ok.txt"}] = report.uploaded_files
      assert_received {:upload, ["ok.txt"], _}
      assert_received {:publish, ^action, _, "Answer", _}
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}
      refute inspect(report) <> logs =~ "private-provider-detail"
      refute inspect(report) <> logs =~ "Req.TransportError"
    end
  end

  test "partial publication reports normalize pending errors even without an explicit policy" do
    for policy <- [nil, :continue, :abort], {reason, category} <- transport_errors() do
      Process.put({PolicyTransport, :publication_error}, reason)
      Process.put({PolicyTransport, :publications}, 0)
      Process.put({PolicyTransport, :fail_publication}, 2)
      files = Enum.map(1..21, &file("#{&1}.txt"))

      {result, logs} = with_log(fn -> post(files, policy) end)
      assert {:ok, sent} = result
      report = sent.response.metadata.delivery_report
      assert report.confirmation == :partial
      assert [%{message_id: "post-1"}] = report.messages
      {failed, pending} = Enum.split(report.failed_files, 10)
      assert length(failed) == 10
      assert Enum.all?(failed, &(&1.reason == category and &1.stage == :transport and &1.delivery == :unconfirmed))
      assert [%{filename: "21.txt", reason: :not_attempted, delivery: :not_sent}] = pending
      assert_received {:publish, :send, nil, "Answer", _}
      assert_received {:publish, :send, nil, "Additional files (2/3).", _}
      refute_received {:publish, _, _, _, _}
      for _ <- 1..if(is_nil(policy), do: 2, else: 3), do: assert_received({:upload, _, _})
      refute_received {:upload, _, _}
      refute inspect(report) <> logs =~ "private-provider-detail"
      refute inspect(report) <> logs =~ "Req.TransportError"
    end
  end

  test "legacy top-level failures retain the original internal transport reason" do
    for {reason, _category} <- transport_errors() do
      Process.put({PolicyTransport, :upload_error}, reason)

      assert {:error, ^reason} =
               Adapter.send_file("room", file("fail.txt"), Keyword.delete(opts(nil), :attachment_failure_policy))

      assert_received {:upload, ["fail.txt"], _}
      refute_received {:publish, _, _, _, _}

      Process.put({PolicyTransport, :publication_error}, reason)
      Process.put({PolicyTransport, :publications}, 0)
      Process.put({PolicyTransport, :fail_publication}, 1)
      assert {:error, ^reason} = post([file("first.txt"), file("second.txt")], nil)
      assert_received {:upload, ["first.txt", "second.txt"], _}
      assert_received {:publish, :send, nil, "Answer", _}
      refute_received {:publish, _, _, _, _}
    end
  end

  defp transport_errors do
    [
      {{413, %{"message" => "private-provider-detail"}}, {:http_error, 413}},
      {{:http_error, 413}, {:http_error, 413}},
      {:timeout, :timeout},
      {%Req.TransportError{reason: :timeout}, :timeout}
    ]
  end

  defp post(files, policy, extra \\ []) do
    thread = Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})
    Thread.post(thread, Postable.text("Answer", files: files), Keyword.merge(opts(policy), extra))
  end

  defp opts(policy), do: [transport: PolicyTransport, max_file_size: 1000, attachment_failure_policy: policy]
  defp file(name, bytes \\ "ok"), do: %FileUpload{filename: name, data: bytes, media_type: "text/plain"}

  defp next_call do
    receive do
      call -> call
    after
      0 -> flunk("expected a transport call")
    end
  end
end
