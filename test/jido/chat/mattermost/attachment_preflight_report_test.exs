defmodule Jido.Chat.Mattermost.AttachmentPreflightReportTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{FileUpload, Postable, SentMessage, Thread}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.PolicyTransport

  @moduletag capture_log: true

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  for route <- [:post, :edit], policy <- [:abort, "abort"], source <- [:bytes, :path], count <- [1, 11] do
    @route route
    @policy policy
    @source source
    @count count

    @tag :tmp_dir
    test "#{route} accounts for #{count} unattempted #{source} files with #{inspect(policy)}", %{tmp_dir: dir} do
      valid = Enum.map(1..@count, &upload("valid-#{&1}.txt", "ok", @source, dir))
      rejected = [upload("large.txt", "too big", @source, dir), upload("larger.txt", "also too big", @source, dir)]
      files = [hd(rejected)] ++ valid ++ tl(rejected)

      assert {:error, {:attachment_delivery_failed, report}} = deliver(@route, files, @policy)
      assert report.confirmation == :not_sent
      assert report.delivery == :not_sent
      assert report.messages == []
      assert report.uploaded_files == []
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}

      assert Enum.sort(Enum.map(report.failed_files, & &1.filename)) ==
               Enum.sort(Enum.map(files, & &1.filename))

      assert Enum.filter(report.failed_files, &(&1.reason == :not_attempted)) ==
               Enum.map(valid, &%{filename: &1.filename, reason: :not_attempted, stage: :upload, delivery: :not_sent})

      rejections =
        report.failed_files
        |> Enum.filter(&(&1.reason == :file_too_large))
        |> Enum.map(&Map.take(&1, [:filename, :size, :limit, :delivery]))

      assert rejections == [
               %{filename: "large.txt", size: 7, limit: 3, delivery: :not_sent},
               %{filename: "larger.txt", size: 12, limit: 3, delivery: :not_sent}
             ]
    end
  end

  for route <- [:post, :edit] do
    @route route

    test "#{route} accounts for a rejected file alone" do
      files = [%FileUpload{filename: "large.txt", data: "too big"}]
      assert {:error, {:attachment_delivery_failed, report}} = deliver(@route, files, :abort)

      assert [%{filename: "large.txt", reason: :file_too_large, size: 7, limit: 3, delivery: :not_sent}] =
               report.failed_files

      assert report.messages == []
      assert report.uploaded_files == []
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}
    end

    test "#{route} continue publishes the valid sibling and reports only the rejected input" do
      files = [%FileUpload{filename: "large.txt", data: "too big"}, %FileUpload{filename: "valid.txt", data: "ok"}]
      assert {:ok, sent} = deliver(@route, files, :continue)
      assert [attachment] = sent.attachments
      assert attachment.filename == "valid.txt"
      report = sent.response.metadata.delivery_report
      assert report.confirmation == :partial
      assert [%{filename: "large.txt", reason: :file_too_large}] = report.failed_files
      assert [%{filename: "valid.txt", file_id: "valid.txt"}] = report.uploaded_files
      assert [message] = report.messages
      assert message.message_id == sent.id
      assert_received {:upload, ["valid.txt"], _}
      assert_received {:publish, action, _, "Answer", publish_opts}
      assert action == if(@route == :post, do: :send, else: :edit)
      assert publish_opts[:file_ids] == ["valid.txt"]
      refute_received {:upload, _, _}
      refute_received {:publish, _, _, _, _}
    end
  end

  defp deliver(:post, files, policy) do
    thread = Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})
    Thread.post(thread, Postable.text("Answer", files: files), opts(policy))
  end

  defp deliver(:edit, files, policy) do
    sent =
      SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "existing", external_room_id: "room"},
        default_opts: opts(policy)
      })

    SentMessage.edit(sent, Postable.text("Answer", files: files))
  end

  defp opts(policy), do: [transport: PolicyTransport, max_file_size: 3, attachment_failure_policy: policy]

  defp upload(name, bytes, :bytes, _dir), do: %FileUpload{filename: name, data: bytes}

  defp upload(name, bytes, :path, dir) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    %FileUpload{filename: name, path: path}
  end
end
