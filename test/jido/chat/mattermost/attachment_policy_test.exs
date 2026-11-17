defmodule Jido.Chat.Mattermost.AttachmentPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{FileUpload, SentMessage, Thread}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
    refute Map.get(Jido.Chat.Adapter.capabilities(Adapter), :attachment_failure_policy) == :native
  end

  for route <- [:send, :file, :post, :edit], policy <- [:abort, :continue, "abort", "continue", :unknown] do
    @route route
    @policy policy
    test "#{route} rejects retired policy #{inspect(policy)} before all transport calls" do
      assert {:error, {:unsupported_option, :attachment_failure_policy}} =
               invoke(@route, attachment_failure_policy: @policy)

      refute_received {:transport_call, _, _}
    end
  end

  test "upload failure does not publish a fallback or claim a confirmed prefix" do
    Process.put({RecordingTransport, :upload_files}, {:error, :timeout})

    for route <- [:file, :post, :edit] do
      assert {:error, :timeout} = invoke(route, [])
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "an old restored policy is rejected explicitly instead of silently changing delivery semantics" do
    sent =
      SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        default_opts: [transport: RecordingTransport, attachment_failure_policy: :continue]
      })

    restored = sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map()
    assert {:error, {:unsupported_option, :attachment_failure_policy}} = SentMessage.edit(restored, "edited")
    refute_received {:transport_call, _, _}
  end

  defp invoke(route, extra) do
    file = %FileUpload{data: "bytes", filename: "file.txt"}
    opts = Keyword.merge([transport: RecordingTransport, max_file_size: 1000], extra)

    case route do
      :send ->
        Adapter.send_message("room", "Answer", opts)

      :file ->
        Adapter.send_file("room", file, opts)

      :post ->
        thread = Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})
        Thread.post(thread, Jido.Chat.Postable.text("Answer", files: [file]), opts)

      :edit ->
        Adapter.edit_message("room", "post", "Answer", Keyword.put(opts, :files, [file]))
    end
  end
end
