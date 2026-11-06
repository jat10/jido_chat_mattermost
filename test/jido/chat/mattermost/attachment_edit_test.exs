defmodule Jido.Chat.Mattermost.AttachmentEditTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.FileUpload
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  setup do
    Process.put({RecordingTransport, :upload_files}, {:ok, %{"file_infos" => [%{"id" => "file"}]}})

    Process.put(
      {RecordingTransport, :edit_message},
      {:ok, %{"id" => "post", "file_ids" => ["file"]}}
    )

    :ok
  end

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
    assert Adapter.capabilities().edit_attachments == :native
  end

  test "SentMessage.edit uploads a file and updates the same message with delivery metadata" do
    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        default_opts: Keyword.delete(opts(), :files)
      })

    payload = Jido.Chat.Postable.text("Answer", files: opts()[:files])
    assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, payload)
    assert edited.id == "post"
    assert edited.response.status == :edited
    assert [attachment] = edited.attachments
    assert attachment.filename == "file.png"
    assert attachment.data == nil
    assert attachment.path == nil
    assert attachment.url == "mattermost://file/file"
    assert {:ok, _} = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode()
    assert [media] = edited.metadata.media
    assert media.metadata.file_id == "file"
    assert_received {:transport_call, :upload_files, ["room", [upload], upload_opts]}
    assert upload == %{body: <<0, 255>>, filename: "file.png", content_type: "image/png"}
    assert upload_opts[:token] == "test-token"
    assert_received {:transport_call, :edit_message, ["room", "post", "Answer", edit_opts]}
    assert edit_opts[:file_ids] == ["file"]
    refute_received {:transport_call, :send_message, _}

    assert {:ok, text_edited} = Jido.Chat.SentMessage.edit(edited, "Revised answer")
    assert text_edited.id == "post"
    assert [attachment] = text_edited.attachments
    assert attachment.metadata.file_id == "file"
    assert attachment.filename == "file.png"
    assert [media] = text_edited.metadata.media
    assert media.metadata.file_id == "file"
    assert media.filename == "file.png"
    assert_received {:transport_call, :edit_message, ["room", "post", "Revised answer", text_opts]}
    refute Keyword.has_key?(text_opts, :file_ids)
    refute_received {:transport_call, :upload_files, _}
  end

  test "replacing an attachment updates the file reference used by fetch_media" do
    transport_opts = Keyword.delete(opts(), :files)
    [replacement] = opts()[:files]
    original_upload = %FileUpload{data: "old", filename: "old.txt", media_type: "text/plain", size_bytes: 3}

    Process.put(
      {RecordingTransport, :upload_files},
      {:ok, %{"file_infos" => [%{"id" => "old", "name" => "old.txt", "mime_type" => "text/plain"}]}}
    )

    Process.put(
      {RecordingTransport, :send_message},
      {:ok, %{"id" => "post", "channel_id" => "room", "file_ids" => ["old"]}}
    )

    assert {:ok, response} = Adapter.send_file("room", original_upload, transport_opts)

    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: response,
        default_opts: transport_opts
      })

    assert sent.metadata.file_id == "old"
    assert sent.metadata.size == 3
    assert_received {:transport_call, :upload_files, _}
    assert_received {:transport_call, :send_message, _}

    Process.put(
      {RecordingTransport, :upload_files},
      {:ok, %{"file_infos" => [%{"id" => "file", "name" => "file.png", "mime_type" => "image/png"}]}}
    )

    payload = Jido.Chat.Postable.text("Replacement", files: [replacement])
    assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, payload)
    assert edited.id == "post"
    assert [media] = edited.metadata.media
    assert media.metadata.file_id == "file"
    refute_received {:transport_call, :send_message, _}

    Process.put({RecordingTransport, :download_file}, {:ok, "replacement bytes"})
    assert {:ok, "replacement bytes"} = Adapter.fetch_media(edited.metadata, transport_opts)
    assert_received {:transport_call, :download_file, ["file", _]}
    assert edited.metadata.file_id == "file"
    assert edited.metadata.file_ids == ["file"]
    assert edited.metadata.attachments == edited.attachments
    assert [attachment] = edited.attachments
    assert attachment.filename == "file.png"
    assert edited.metadata.filename == "file.png"
    assert edited.metadata.content_type == "image/png"
    assert edited.metadata.size == nil
    assert edited.metadata.delivered_kind == :image
    assert edited.metadata.upload["file_infos"] |> hd() |> Map.fetch!("id") == "file"
  end

  test "restored SDK handles serialize the latest replacement media and file IDs" do
    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        default_opts: []
      })

    transport_opts = Keyword.delete(opts(), :files)

    payload =
      Jido.Chat.Postable.text("Answer", files: [%FileUpload{data: <<0, 255, 128>>, filename: "report.bin"}])

    assert {:ok, first} = Jido.Chat.SentMessage.edit(sent, payload, transport_opts)
    restored = first |> Jido.Chat.SentMessage.to_map() |> Jido.Chat.SentMessage.from_map()

    Process.put({RecordingTransport, :upload_files}, {:ok, %{"file_infos" => [%{"id" => "replacement"}]}})
    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => ["replacement"]}})

    assert {:ok, edited} = Jido.Chat.SentMessage.edit(restored, payload, transport_opts)
    serialized = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!()
    assert serialized["metadata"]["file_id"] == "replacement"
    assert serialized["metadata"]["file_ids"] == ["replacement"]
    assert [%{"metadata" => %{"file_id" => "replacement"}}] = serialized["metadata"]["media"]
    refute_received {:transport_call, :send_message, _}
  end

  test "upload failure or missing ID cannot edit or create a post" do
    for {result, error} <- [
          {{:error, :timeout}, :timeout},
          {{:ok, %{"file_infos" => []}}, :missing_uploaded_file_id}
        ] do
      Process.put({RecordingTransport, :upload_files}, result)
      assert {:error, ^error} = Adapter.edit_message("room", "post", "Answer", opts())
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, :edit_message, _}
      refute_received {:transport_call, :send_message, _}
    end
  end

  test "edit failure never retries an upload or creates another post" do
    Process.put({RecordingTransport, :edit_message}, {:error, :timeout})
    assert {:error, :timeout} = Adapter.edit_message("room", "post", "Answer", opts())
    assert_received {:transport_call, :upload_files, _}
    assert_received {:transport_call, :edit_message, _}
    refute_received {:transport_call, _, _}
  end

  test "a successful edit that omits the uploaded file is not confirmed" do
    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => []}})

    assert {:error, :unconfirmed_delivery} =
             Adapter.edit_message("room", "post", "Answer", opts())
  end

  test "text-only edits preserve media metadata for existing attachments" do
    post = %{
      "id" => "post",
      "channel_id" => "room",
      "message" => "Updated answer",
      "file_ids" => ["existing"],
      "metadata" => %{
        "files" => [
          %{
            "id" => "existing",
            "name" => "existing.png",
            "mime_type" => "image/png",
            "size" => 42
          }
        ]
      }
    }

    Process.put({RecordingTransport, :edit_message}, {:ok, post})

    assert {:ok, response} =
             Adapter.edit_message("room", "post", "Updated answer", Keyword.delete(opts(), :files))

    assert_received {:transport_call, :edit_message, ["room", "post", "Updated answer", edit_opts]}
    refute Keyword.has_key?(edit_opts, :file_ids)
    refute_received {:transport_call, :upload_files, _}

    assert [media] = response.metadata.media
    assert media.metadata.file_id == "existing"
    assert media.url == "mattermost://file/existing"
    assert media.filename == "existing.png"
    assert media.media_type == "image/png"
    assert media.size_bytes == 42

    Process.put({RecordingTransport, :upload_files}, {:ok, %{"file_infos" => post["metadata"]["files"]}})
    Process.put({RecordingTransport, :send_message}, {:ok, post})
    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => ["existing"]}})
    transport_opts = Keyword.delete(opts(), :files)
    upload = %FileUpload{data: <<0, 255>>, filename: "existing.png", media_type: "image/png"}

    for owner <- [Jido.Chat.Thread, Jido.Chat.ChannelRef], mode <- [:send_file, :post] do
      handle =
        owner.new(%{
          id: "room",
          adapter_name: :mattermost,
          adapter: Adapter,
          external_room_id: "room",
          external_id: "room"
        })

      input = if mode == :send_file, do: upload, else: Jido.Chat.Postable.text("File", files: [upload])
      assert {:ok, sent} = apply(owner, mode, [handle, input, transport_opts])
      assert sent.metadata == %{}
      assert sent.response.metadata.filename == "existing.png"
      assert {:ok, _} = sent.response.metadata |> Jido.Chat.Wire.to_plain() |> Jason.encode()
      assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, "Sparse reply", transport_opts)
      assert edited.metadata.filename == "existing.png"
      assert edited.metadata.content_type == "image/png"
      assert edited.metadata.size == 42
      assert [attachment] = edited.attachments
      assert attachment.filename == "existing.png"
      assert attachment.url == "mattermost://file/existing"
      assert {:ok, _} = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode()
    end
  end

  test "text-only edits refresh file references after an external attachment replacement" do
    transport_opts = Keyword.delete(opts(), :files)

    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{
          external_message_id: "post",
          external_room_id: "room",
          metadata: %{
            file_id: "old",
            file_ids: ["old"],
            filename: "old.txt",
            content_type: "text/plain",
            size: 123,
            upload_kind: :file,
            upload: %{"file_infos" => [%{"id" => "old"}]},
            media: [%{url: "mattermost://file/old", metadata: %{file_id: "old"}}]
          }
        },
        default_opts: transport_opts
      })

    # Another client replaced the attachment after this handle was created.
    post = %{
      "id" => "post",
      "channel_id" => "room",
      "message" => "Updated text",
      "file_ids" => ["remote"],
      "metadata" => %{
        "files" => [%{"id" => "remote", "name" => "new.pdf", "mime_type" => "application/pdf"}]
      }
    }

    Process.put({RecordingTransport, :edit_message}, {:ok, post})

    assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, "Updated text")
    assert edited.id == "post"
    assert [media] = edited.metadata.media
    assert media.metadata.file_id == "remote"
    assert_received {:transport_call, :edit_message, ["room", "post", "Updated text", forwarded]}
    refute Keyword.has_key?(forwarded, :file_ids)
    refute_received {:transport_call, :upload_files, _}
    refute_received {:transport_call, :send_message, _}

    Process.put({RecordingTransport, :download_file}, {:ok, "new PDF bytes"})
    assert {:ok, "new PDF bytes"} = Adapter.fetch_media(edited.metadata, transport_opts)
    assert_received {:transport_call, :download_file, ["remote", _]}
    assert edited.metadata.file_id == "remote"
    assert edited.metadata.file_ids == ["remote"]
    assert edited.metadata.filename == "new.pdf"
    assert edited.metadata.content_type == "application/pdf"
    assert edited.metadata.size == nil
    assert edited.metadata.upload == nil
    assert edited.metadata.upload_kind == nil
  end

  test "text-only edits clear stale file metadata when the server reports no attachments" do
    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        metadata: %{file_id: "old", file_ids: ["old"], filename: "old.txt", size: 123, upload: %{old: true}},
        attachments: [%{filename: "old.txt", data: "old bytes"}],
        default_opts: Keyword.delete(opts(), :files)
      })

    for post <- [
          %{"id" => "post", "file_ids" => []},
          %{"id" => "post", "metadata" => %{"files" => []}},
          %{id: "post", metadata: %{files: []}}
        ] do
      Process.put({RecordingTransport, :edit_message}, {:ok, post})
      assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, "Updated text")
      assert edited.attachments == []
      assert edited.metadata.media == []
      assert edited.metadata.file_ids == []
      assert edited.metadata.file_id == nil
      assert edited.metadata.filename == nil
      assert edited.metadata.size == nil
      assert edited.metadata.upload == nil
      assert {:error, :invalid_media_reference} = Adapter.fetch_media(edited.metadata, opts())
      refute_received {:transport_call, :download_file, _}
      refute_received {:transport_call, :upload_files, _}
    end
  end

  test "text-only edits retain all server file IDs when file metadata is incomplete" do
    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        metadata: %{
          file_id: "one",
          file_ids: ["one", "two"],
          filename: "one.txt",
          content_type: "text/plain; charset=utf-8",
          media: [
            %{
              url: "mattermost://file/two",
              filename: "two.png",
              media_type: "image/png",
              size_bytes: 42,
              metadata: %{file_id: "two"}
            }
          ]
        },
        default_opts: Keyword.delete(opts(), :files)
      })

    # Both files remain attached, but details are available for only the first.
    post = %{
      "id" => "post",
      "channel_id" => "room",
      "file_ids" => ["one", "two"],
      "metadata" => %{
        "files" => [%{"id" => "one", "name" => "one.pdf", "mime_type" => "application/pdf"}]
      }
    }

    Process.put({RecordingTransport, :edit_message}, {:ok, post})

    assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, "Updated text")
    assert edited.id == "post"
    assert edited.response.raw["file_ids"] == ["one", "two"]
    assert_received {:transport_call, :edit_message, ["room", "post", "Updated text", forwarded]}
    refute Keyword.has_key?(forwarded, :file_ids)
    refute_received {:transport_call, :upload_files, _}
    refute_received {:transport_call, :send_message, _}

    assert edited.metadata.file_ids == ["one", "two"]
    assert Enum.map(edited.metadata.media, & &1.metadata.file_id) == ["one", "two"]
    assert Enum.at(edited.metadata.media, 1).url == "mattermost://file/two"
    assert Enum.at(edited.metadata.media, 1).filename == "two.png"
    assert Enum.at(edited.metadata.media, 1).size_bytes == 42
    assert Enum.at(edited.attachments, 1).media_type == "image/png"
    serialized = Jido.Chat.SentMessage.to_map(edited)
    assert serialized["metadata"]["file_ids"] == ["one", "two"]

    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => ["one", "two"]}})
    restored = sent |> Jido.Chat.SentMessage.to_map() |> Map.put("default_opts", []) |> Jido.Chat.SentMessage.from_map()
    assert {:ok, sparse} = Jido.Chat.SentMessage.edit(restored, "Sparse response", Keyword.delete(opts(), :files))
    assert sparse.metadata.filename == "one.txt"
    assert sparse.metadata.content_type == "text/plain; charset=utf-8"
    assert Enum.at(sparse.metadata.media, 1).filename == "two.png"
  end

  test "server file IDs determine attachment membership and order regardless of available details" do
    sent =
      Jido.Chat.SentMessage.new(%{
        adapter: Adapter,
        response: %{external_message_id: "post", external_room_id: "room"},
        metadata: %{file_id: "old", file_ids: ["old"], filename: "old.txt"},
        default_opts: Keyword.delete(opts(), :files)
      })

    for {ids, details} <- [
          {["remote"], %{}},
          {["remote"], %{"metadata" => %{"files" => []}}},
          {["one", "two"], %{"metadata" => %{"files" => [%{"id" => "two"}, %{"id" => "one"}, %{"id" => "old"}]}}},
          {[], %{"metadata" => %{"files" => [%{"id" => "old"}]}}}
        ] do
      post = Map.merge(%{"id" => "post", "file_ids" => ids}, details)
      Process.put({RecordingTransport, :edit_message}, {:ok, post})

      restored =
        sent |> Jido.Chat.SentMessage.to_map() |> Map.put("default_opts", []) |> Jido.Chat.SentMessage.from_map()

      assert {:ok, edited} =
               Jido.Chat.SentMessage.edit(restored, "Updated text", Keyword.delete(opts(), :files))

      assert edited.metadata.file_ids == ids
      assert edited.metadata.file_id == List.first(ids)
      assert Enum.map(edited.metadata.media, & &1.metadata[:file_id]) == ids
      assert edited.metadata.filename == nil
      assert Jido.Chat.SentMessage.to_map(edited)["metadata"]["file_ids"] == ids
      refute_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, :send_message, _}
    end
  end

  test "text-only edits omit file IDs" do
    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post"}})

    assert {:ok, response} =
             Adapter.edit_message("room", "post", "Answer", Keyword.delete(opts(), :files))

    refute Map.has_key?(response.metadata, :media)
    assert_received {:transport_call, :edit_message, ["room", "post", "Answer", edit_opts]}
    refute Keyword.has_key?(edit_opts, :file_ids)
    refute_received {:transport_call, :upload_files, _}
  end

  test "multiple uploads produce one post or edit with server-ordered attachment metadata" do
    for operation <- [:post, :edit] do
      Process.put(
        {RecordingTransport, :upload_files},
        {:ok, %{"file_infos" => [%{"id" => "one", "name" => "one.bin"}, %{"id" => "two", "name" => "two.txt"}]}}
      )

      result = {:ok, %{"id" => "post", "channel_id" => "room", "file_ids" => ["two", "one"]}}
      Process.put({RecordingTransport, :send_message}, result)
      Process.put({RecordingTransport, :edit_message}, result)
      assert {:ok, response} = multi_operation(operation)
      assert response.metadata.file_ids == ["two", "one"]
      assert Enum.map(response.metadata.media, & &1.metadata.file_id) == ["two", "one"]
      assert Enum.map(response.metadata.attachments, & &1.filename) == ["two.txt", "one.bin"]
      assert {:ok, _} = response.metadata |> Jido.Chat.Wire.to_plain() |> Jason.encode()
      assert_received {:transport_call, :upload_files, ["room", [%{body: <<0, 255>>}, %{body: "two"}], _]}

      case operation do
        :post ->
          assert_received {:transport_call, :send_message, ["room", "Files", forwarded]}
          assert forwarded[:file_ids] == ["one", "two"]
          assert forwarded[:thread_id] == "root"

        :edit ->
          assert_received {:transport_call, :edit_message, ["room", "post", "Files", forwarded]}
          assert forwarded[:file_ids] == ["one", "two"]
      end

      refute_received {:transport_call, _, _}
    end
  end

  test "failed or incomplete batch uploads prevent posting a partial attachment set" do
    for operation <- [:post, :edit],
        {result, reason} <- [
          {{:error, {413, "too large"}}, {413, "too large"}},
          {{:error, :timeout}, :timeout},
          {{:ok, %{"file_infos" => []}}, :missing_uploaded_file_id},
          {{:ok, %{"file_infos" => [%{"id" => "one"}]}}, :unconfirmed_upload},
          {{:ok, %{"file_infos" => [%{"id" => "one"}, %{"id" => "one"}]}}, :unconfirmed_upload},
          {{:ok, %{"file_infos" => [%{"id" => "one"}, %{"name" => "missing-id"}]}}, :unconfirmed_upload}
        ] do
      Process.put({RecordingTransport, :upload_files}, result)
      assert {:error, ^reason} = multi_operation(operation)
      assert_received {:transport_call, :upload_files, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "multiple-file delivery must confirm every uploaded ID" do
    for operation <- [:post, :edit] do
      Process.put({RecordingTransport, :upload_files}, {:ok, %{"file_infos" => [%{"id" => "one"}, %{"id" => "two"}]}})

      Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "post", "file_ids" => ["one"]}})
      Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => ["one"]}})
      assert {:error, :unconfirmed_delivery} = multi_operation(operation)
      assert_received {:transport_call, :upload_files, _}
      callback = if operation == :post, do: :send_message, else: :edit_message
      assert_received {:transport_call, ^callback, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "an invalid later file is rejected before any upload" do
    [valid] = opts()[:files]
    files = [valid, %FileUpload{filename: "missing.txt"}]
    payload = Jido.Chat.PostPayload.new(%{text: "Files", files: files})
    assert {:error, :missing_file_source} = Adapter.post_message("room", payload, opts())

    assert {:error, :missing_file_source} =
             Adapter.edit_message("room", "post", "Files", Keyword.put(opts(), :files, files))

    refute_received {:transport_call, _, _}
  end

  defp multi_operation(operation) do
    payload =
      Jido.Chat.Postable.text("Files",
        files: [
          %FileUpload{data: <<0, 255>>, filename: "one.bin"},
          %FileUpload{data: "two", filename: "two.txt"}
        ]
      )

    options = opts() |> Keyword.delete(:files) |> Keyword.put(:thread_id, "root")

    case operation do
      :post ->
        Jido.Chat.Adapter.post_message(Adapter, "room", Jido.Chat.Postable.to_payload(payload), options)

      :edit ->
        sent =
          Jido.Chat.SentMessage.new(%{
            adapter: Adapter,
            response: %{external_message_id: "post", external_room_id: "room"}
          })

        case Jido.Chat.SentMessage.edit(sent, payload, options) do
          {:ok, edited} -> {:ok, edited.response}
          error -> error
        end
    end
  end

  defp opts do
    [
      transport: RecordingTransport,
      token: "test-token",
      files: [
        %FileUpload{kind: :file, data: <<0, 255>>, filename: "file.png", media_type: "image/png"}
      ]
    ]
  end
end
