defmodule Jido.Chat.Mattermost.AttachmentPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jido.Chat.{FileUpload, Postable, PostPayload, SentMessage, Thread}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.{PolicyTransport, RecordingTransport}

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

  for action <- [:post, :edit], failed_group <- [1, 2] do
    @action action
    @failed_group failed_group

    @tag capture_log: true
    test "strict #{@action} reports unattempted files after upload group #{@failed_group} fails" do
      files =
        Enum.map(1..21, fn index ->
          file(if index == (@failed_group - 1) * 10 + 1, do: "fail.txt", else: "#{index}.txt")
        end)

      result =
        case @action do
          :post -> post(files, :abort)
          :edit -> Adapter.edit_message("room", "existing", "Answer", Keyword.put(opts(:abort), :files, files))
        end

      assert {:error, {:attachment_delivery_failed, report}} = result
      assert report.delivery == :not_sent
      assert report.messages == []

      for group <- files |> Enum.chunk_every(10) |> Enum.take(@failed_group) do
        assert {:upload, names, _opts} = next_call()
        assert names == Enum.map(group, & &1.filename)
      end

      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}

      uploaded = Enum.take(files, (@failed_group - 1) * 10)
      assert Enum.map(report.uploaded_files, & &1.filename) == Enum.map(uploaded, & &1.filename)

      expected_pending =
        files
        |> Enum.drop(@failed_group * 10)
        |> Enum.map(&%{filename: &1.filename, reason: :not_attempted, stage: :upload, delivery: :not_sent})

      assert Enum.filter(report.failed_files, &(&1.reason == :not_attempted)) == expected_pending

      reported_names = Enum.map(report.uploaded_files ++ report.failed_files, & &1.filename)
      assert Enum.sort(reported_names) == Enum.sort(Enum.map(files, & &1.filename))
    end
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
    assert sent.attachments == []
    assert sent.response.metadata.attachments == []
    refute_received {:publish, _, _, _, _}
  end

  test "continue edit retains server attachments when all replacement uploads fail" do
    assert {:ok, sent} = post([file("existing.txt")], :continue)
    assert [existing] = sent.attachments

    assert {:ok, edited} = SentMessage.edit(sent, Postable.text("Updated", files: [file("fail.txt")]))

    assert edited.id == sent.id
    assert edited.text == "Updated"
    assert edited.response.raw["message"] == "Updated"
    assert edited.response.raw["file_ids"] == ["existing.txt"]
    assert edited.attachments == [existing]
    assert edited.response.metadata.attachments == [existing]
    assert edited.metadata.attachments == [existing]
    assert edited.response.metadata.file_ids == ["existing.txt"]

    assert %{confirmation: :partial, failed_files: [%{filename: "fail.txt", stage: :upload}]} =
             edited.response.metadata.delivery_report

    assert_received {:publish, :edit, _, "Updated", edit_opts}
    assert edit_opts[:file_ids] == []
  end

  test "continue edit honors server-confirmed removal when all replacement uploads fail" do
    assert {:ok, sent} = post([file("existing.txt")], :continue)
    Process.put({PolicyTransport, :edit_file_ids}, [])

    assert {:ok, edited} = SentMessage.edit(sent, Postable.text("Updated", files: [file("fail.txt")]))
    assert edited.attachments == []
    assert edited.response.metadata.attachments == []
    assert edited.response.metadata.file_ids == []
    assert [%{filename: "fail.txt"}] = edited.response.metadata.delivery_report.failed_files
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

  for action <- [:send, :edit], later_upload_succeeds? <- [false, true] do
    @action action
    @later_upload_succeeds later_upload_succeeds?

    @tag capture_log: true
    test "continue #{@action} retains text publication failure after failed uploads (successful later group: #{@later_upload_succeeds})" do
      Process.put({PolicyTransport, :fail_publication}, 1)
      Process.put({PolicyTransport, :publication_error}, {:http_error, 401})
      failed_group = [file("fail.txt") | Enum.map(2..10, &file("#{&1}.txt"))]
      files = if @later_upload_succeeds, do: failed_group ++ [file("11.txt")], else: failed_group

      result =
        case @action do
          :send -> post(files, :continue)
          :edit -> Adapter.edit_message("room", "existing", "Answer", Keyword.put(opts(:continue), :files, files))
        end

      assert {:error, {:attachment_delivery_failed, report}} = result
      assert report.delivery == :unconfirmed
      assert report.stage == :transport
      assert report.messages == []
      assert {:upload, failed_names, _} = next_call()
      assert failed_names == Enum.map(failed_group, & &1.filename)

      if @later_upload_succeeds do
        assert {:upload, ["11.txt"], _} = next_call()
        assert report.uploaded_files == [%{filename: "11.txt", file_id: "11.txt"}]

        assert List.last(report.failed_files) == %{
                 filename: "11.txt",
                 reason: :not_attempted,
                 stage: :transport,
                 delivery: :not_sent
               }
      else
        assert report.uploaded_files == []
      end

      assert {:publish, @action, _, "Answer", publication_opts} = next_call()
      assert publication_opts[:file_ids] in [nil, []]
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}

      expected_upload_failures =
        Enum.map(failed_group, &%{filename: &1.filename, reason: :upload_rejected, stage: :upload, delivery: :not_sent})

      assert Enum.filter(report.failed_files, &(&1.stage == :upload)) == expected_upload_failures
      assert Map.fetch(report, :reason) == {:ok, {:http_error, 401}}
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

  for restored? <- [false, true] do
    @restored restored?

    test "successful policy edit clears a previous partial report (restored: #{@restored})" do
      assert {:ok, sent} = post([file("old.txt"), file("old-large.txt", "too big")], :continue, max_file_size: 3)

      assert %{confirmation: :partial, failed_files: [%{filename: "old-large.txt"}]} =
               sent.response.metadata.delivery_report

      sent =
        if @restored,
          do: sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map(),
          else: sent

      assert {:ok, edited} = SentMessage.edit(sent, Postable.text("Replacement", files: [file("new.txt")]))
      assert [%{filename: "new.txt"}] = edited.attachments
      assert edited.response.metadata.attachments == edited.attachments
      assert Map.get(edited.metadata, :delivery_report, Map.get(edited.metadata, "delivery_report")) == nil
      assert Map.fetch(edited.response.metadata, :delivery_report) == {:ok, nil}
      assert Map.fetch(edited.metadata, :delivery_report) == {:ok, nil}
      serialized = edited |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!()
      assert serialized["metadata"]["delivery_report"] == nil
      refute Map.has_key?(edited.metadata, "delivery_report")
    end
  end

  test "partial policy replacement replaces an earlier report with only current failures" do
    assert {:ok, sent} = post([file("old.txt"), file("old-large.txt", "too big")], :continue, max_file_size: 3)
    assert [%{filename: "old-large.txt"}] = sent.response.metadata.delivery_report.failed_files

    replacement = Postable.text("Replacement", files: [file("new.txt"), file("new-large.txt", "too big")])
    assert {:ok, edited} = SentMessage.edit(sent, replacement)
    assert [%{filename: "new.txt"}] = edited.attachments

    assert %{confirmation: :partial, messages: [message], failed_files: [%{filename: "new-large.txt"}]} =
             edited.response.metadata.delivery_report

    assert message.message_id == sent.id
    assert message.action == :updated
    assert message.body == "Replacement"
    assert message.metadata.file_ids == ["new.txt"]
    assert edited.metadata.delivery_report == edited.response.metadata.delivery_report
  end

  for policy <- [:abort, :continue] do
    @policy policy

    test "serialized #{@policy} policy posts with normalized transport options" do
      assert {:ok, sent} = post([file("ok.txt")], Atom.to_string(@policy))
      assert [%{filename: "ok.txt"}] = sent.attachments
      assert_received {:upload, ["ok.txt"], upload_opts}
      assert upload_opts[:attachment_failure_policy] == @policy
    end

    test "restored #{@policy} handle edits with its saved policy and preserves failure behavior" do
      assert {:ok, sent} = post([file("existing.txt")], @policy)
      restored = sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map()
      assert restored.default_opts[:attachment_failure_policy] == Atom.to_string(@policy)
      assert_received {:upload, ["existing.txt"], _}
      assert_received {:publish, :send, nil, "Answer", _}

      assert {:ok, edited} = SentMessage.edit(restored, Postable.text("Replacement", files: [file("new.txt")]))
      assert edited.id == restored.id
      assert [%{filename: "new.txt"}] = edited.attachments
      assert_received {:upload, ["new.txt"], upload_opts}
      assert upload_opts[:attachment_failure_policy] == @policy
      assert_received {:publish, :edit, _, "Replacement", _}

      result = SentMessage.edit(edited, Postable.text("Failed replacement", files: [file("fail.txt")]))

      report =
        if @policy == :abort do
          assert {:error, {:attachment_delivery_failed, report}} = result
          assert report.delivery == :not_sent
          refute_received {:publish, _, _, _, _}
          report
        else
          assert {:ok, continued} = result
          assert [%{filename: "new.txt"}] = continued.attachments
          assert_received {:publish, :edit, _, "Failed replacement", _}
          continued.response.metadata.delivery_report
        end

      assert [%{filename: "fail.txt", stage: :upload}] = report.failed_files
      assert_received {:upload, ["fail.txt"], failed_opts}
      assert failed_opts[:attachment_failure_policy] == @policy
    end
  end

  test "unknown explicit policy fails before effects" do
    for policy <- [:invalid, "invalid", "ABORT", "", false, 1, %{}] do
      assert {:error, {:invalid_attachment_failure_policy, ^policy}} = post([file("ok.txt")], policy)
    end

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
    for {reason, category} <- transport_errors(), action <- [:send, :edit], policy <- [:continue, :abort] do
      Process.put({PolicyTransport, :publication_error}, reason)
      Process.put({PolicyTransport, :publications}, 0)
      Process.put({PolicyTransport, :fail_publication}, 1)

      {result, logs} =
        with_log(fn ->
          if action == :send,
            do: post([file("ok.txt")], policy),
            else:
              Adapter.edit_message(
                "room",
                "placeholder",
                "Answer",
                Keyword.put(opts(policy), :files, [file("ok.txt")])
              )
        end)

      assert {:error, {:attachment_delivery_failed, report}} = result
      assert report.delivery == :unconfirmed
      assert report.messages == []
      assert [%{reason: ^category, stage: :transport, delivery: :unconfirmed}] = report.failed_files
      assert [%{filename: "ok.txt", file_id: "ok.txt"}] = report.uploaded_files
      assert_received {:upload, ["ok.txt"], _}
      assert_received {:publish, ^action, _, "Answer", publication_opts}
      assert publication_opts[:attachment_failure_policy] == policy
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
      {%{reason: :timeout, detail: "private-provider-detail"}, :timeout},
      {%{reason: {:unknown, "private-provider-detail"}}, :attachment_delivery_failed},
      {{:unknown, "private-provider-detail"}, :attachment_delivery_failed},
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

  describe "attachment error boundaries" do
    @describetag capture_log: true

    for source <- [:bytes, :path], count <- [1, 2], stage <- [:upload, :publication], failure <- [:exception, :exit] do
      @source source
      @count count
      @stage stage
      @failure failure

      @tag :tmp_dir
      test "#{count} #{source} file edit returns an error for #{stage} #{failure} without an explicit policy", %{
        tmp_dir: tmp_dir
      } do
        files = Enum.map(1..@count, &boundary_file(@source, &1, tmp_dir))
        ids = Enum.map(1..@count, &"file-#{&1}")

        Process.put(
          {RecordingTransport, :upload_files},
          {:ok, %{"file_infos" => Enum.map(ids, &%{"id" => &1})}}
        )

        Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "existing-post", "file_ids" => ids}})

        callback = if @stage == :upload, do: :upload_files, else: :edit_message
        failure = @failure

        Process.put({RecordingTransport, callback}, fn -> boundary_transport_failure(failure) end)

        expected = if @failure == :exception, do: :transport_exception, else: :transport_exit

        assert {:error, ^expected} =
                 Adapter.edit_message("room", "existing-post", "Updated answer",
                   files: files,
                   transport: RecordingTransport,
                   max_file_size: 1024
                 )

        assert_received {:transport_call, :upload_files, ["room", _, _]}
        refute_received {:transport_call, :upload_files, _}

        if @stage == :publication do
          assert_received {:transport_call, :edit_message, ["room", "existing-post", "Updated answer", opts]}
          assert opts[:file_ids] == ids
        end

        refute_received {:transport_call, :edit_message, _}
        refute_received {:transport_call, :send_message, _}
      end
    end
  end

  defp boundary_transport_failure(:exception), do: raise("simulated transport failure")
  defp boundary_transport_failure(:exit), do: exit(:simulated_transport_failure)

  defp boundary_file(:bytes, index, _tmp_dir), do: %FileUpload{data: "content", filename: "#{index}.txt"}

  defp boundary_file(:path, index, tmp_dir) do
    path = Path.join(tmp_dir, "#{index}.txt")
    File.write!(path, "content")
    %FileUpload{path: path, filename: "#{index}.txt"}
  end

  describe "attachment delivery routes" do
    @describetag capture_log: true

    for route <- [:send_file, :post, :edit],
        count <- [1, 2],
        source <- [:bytes, :path],
        policy <- [nil, :abort, :continue, "abort", "continue"],
        not (route == :send_file and count == 2) do
      @route route
      @count count
      @source source
      @policy policy

      @tag :tmp_dir
      test "#{route} #{count} #{source} files forwards #{inspect(policy)} and publishes once", %{tmp_dir: tmp_dir} do
        files = Enum.map(1..@count, &route_file(@source, &1, tmp_dir))
        ids = Enum.map(1..@count, &"file-#{&1}")
        Process.put({RecordingTransport, :upload_files}, {:ok, %{"file_infos" => Enum.map(ids, &%{"id" => &1})}})
        post = {:ok, %{"id" => "post", "file_ids" => ids}}
        Process.put({RecordingTransport, :send_message}, post)
        Process.put({RecordingTransport, :edit_message}, post)
        opts = route_policy_opts(@policy, transport: RecordingTransport, max_file_size: 1024)

        assert {:ok, response} = route_invoke(@route, files, opts)
        assert response.external_message_id == "post"
        assert response.metadata.file_ids == ids
        assert Enum.map(response.metadata.attachments, & &1.metadata.file_id) == ids
        refute response.metadata[:delivery_report]
        assert_received {:transport_call, :upload_files, ["room", inputs, upload_opts]}
        assert length(inputs) == @count
        assert Enum.all?(inputs, &Map.has_key?(&1, if(@source == :path, do: :path, else: :body)))
        expected = route_normalized(@policy)
        assert upload_opts[:attachment_failure_policy] == expected
        callback = if @route == :edit, do: :edit_message, else: :send_message
        assert_received {:transport_call, ^callback, args}
        assert Enum.at(args, -2) == "Caption"
        assert List.last(args)[:file_ids] == ids
        assert List.last(args)[:attachment_failure_policy] == expected
        refute_received {:transport_call, _, _}
      end
    end

    test "all routes reject invalid policies before validation or transport effects" do
      for route <- [:send_file, :post, :edit, :send_text, :post_text, :edit_text],
          files <- [
            [],
            [%FileUpload{data: "bytes", filename: "one.txt"}],
            [%FileUpload{data: "one", filename: "one.txt"}, %FileUpload{data: "two", filename: "two.txt"}]
          ],
          policy <- [:invalid, "invalid", false] do
        assert {:error, {:invalid_attachment_failure_policy, ^policy}} =
                 route_invoke(route, files, transport: RecordingTransport, attachment_failure_policy: policy)

        refute_received {:transport_call, _, _}
      end
    end

    test "text routes normalize policies without requiring an upload limit or uploading" do
      for route <- [:send_text, :post_text, :edit_text], policy <- [nil, :abort, :continue, "abort", "continue"] do
        Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "post"}})
        Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => []}})

        assert {:ok, response} =
                 route_invoke(route, [], route_policy_opts(policy, transport: RecordingTransport, max_file_size: nil))

        assert response.external_message_id == "post"
        callback = if route == :edit_text, do: :edit_message, else: :send_message
        assert_received {:transport_call, ^callback, args}
        assert List.last(args)[:attachment_failure_policy] == route_normalized(policy)
        refute_received {:transport_call, _, _}
      end
    end

    test "omitted policy preserves ordinary returned upload and publication errors on every file route" do
      for route <- [:send_file, :post, :edit],
          count <- [1, 2],
          not (route == :send_file and count == 2),
          stage <- [:upload, :publication] do
        files = Enum.map(1..count, &%FileUpload{data: "bytes", filename: "#{&1}.txt"})
        reason = {503, %{"message" => "original transport error"}}
        callback = if route == :edit, do: :edit_message, else: :send_message

        Process.put(
          {RecordingTransport, :upload_files},
          {:ok, %{"file_infos" => Enum.map(1..count, &%{"id" => "file-#{&1}"})}}
        )

        Process.put({RecordingTransport, if(stage == :upload, do: :upload_files, else: callback)}, {:error, reason})
        assert {:error, ^reason} = route_invoke(route, files, transport: RecordingTransport, max_file_size: 1024)
        assert_received {:transport_call, :upload_files, _}
        if stage == :publication, do: assert_received({:transport_call, ^callback, _})
        refute_received {:transport_call, _, _}
      end
    end
  end

  defp route_invoke(:send_file, files, opts),
    do: Adapter.send_file("room", List.first(files), Keyword.put(opts, :caption, "Caption"))

  defp route_invoke(:post, files, opts),
    do: Adapter.post_message("room", PostPayload.text("Caption", files: files), opts)

  defp route_invoke(:edit, files, opts),
    do: Adapter.edit_message("room", "post", "Caption", Keyword.put(opts, :files, files))

  defp route_invoke(:send_text, _files, opts), do: Adapter.send_message("room", "Caption", opts)
  defp route_invoke(:post_text, _files, opts), do: Adapter.post_message("room", PostPayload.text("Caption"), opts)

  defp route_invoke(:edit_text, _files, opts),
    do: Adapter.edit_message("room", "post", "Caption", Keyword.put(opts, :files, []))

  defp route_policy_opts(nil, opts), do: opts
  defp route_policy_opts(policy, opts), do: Keyword.put(opts, :attachment_failure_policy, policy)
  defp route_normalized("abort"), do: :abort
  defp route_normalized("continue"), do: :continue
  defp route_normalized(policy), do: policy
  defp route_file(:bytes, index, _tmp_dir), do: %FileUpload{data: "content", filename: "#{index}.txt"}

  defp route_file(:path, index, tmp_dir) do
    path = Path.join(tmp_dir, "#{index}.txt")
    File.write!(path, "content")
    %FileUpload{path: path, filename: "#{index}.txt"}
  end
end
