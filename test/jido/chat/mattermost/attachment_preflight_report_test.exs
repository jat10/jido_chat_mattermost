defmodule Jido.Chat.Mattermost.AttachmentPreflightReportTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{FileUpload, PostPayload}
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  test "preflight rejects any oversized sibling without omitting files or publishing text" do
    valid = %FileUpload{data: "x", filename: "valid.txt"}
    large = %FileUpload{data: "xx", filename: "large.txt"}

    for files <- [[valid, large], [large, valid]], route <- [:post, :edit] do
      opts = [transport: RecordingTransport, max_file_size: 1]

      result =
        if route == :post,
          do: Adapter.post_message("room", PostPayload.text("Answer", files: files), opts),
          else: Adapter.edit_message("room", "existing", "Answer", Keyword.put(opts, :files, files))

      assert {:error, {:file_too_large, %{filename: "large.txt", size: 2, limit: 1}}} = result
      refute_received {:transport_call, _, _}
    end
  end

  test "metadata-only validation retains filename and limit without reading lazy inputs" do
    assert :ok = Adapter.validate_files([%{name: "lazy.txt", size: 1}], max_file_size: 1)

    assert {:error, {:file_too_large, %{filename: "lazy.txt", size: 2, limit: 1}}} =
             Adapter.validate_files([%{name: "lazy.txt", size: 2}], max_file_size: 1)

    refute_received {:transport_call, _, _}
  end
end
