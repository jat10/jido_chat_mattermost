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

    restored =
      first |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> Jido.Chat.SentMessage.from_map()

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

  for entry <- [:send_file, :post_message], missing <- [:attachment, :message_id] do
    @single_entry entry
    @missing_confirmation missing
    test "#{entry} rejects single-file delivery without confirmed #{missing}" do
      post =
        case @missing_confirmation do
          :attachment -> %{"id" => "post", "file_ids" => []}
          :message_id -> %{"file_ids" => ["file"]}
        end

      Process.put({RecordingTransport, :send_message}, {:ok, post})
      [upload] = opts()[:files]

      input =
        if @single_entry == :send_file, do: upload, else: Jido.Chat.PostPayload.new(%{text: "File", files: [upload]})

      assert {:error, :unconfirmed_delivery} = apply(Adapter, @single_entry, ["room", input, opts()])
      assert_received {:transport_call, :upload_files, _}
      assert_received {:transport_call, :send_message, _}
      refute_received {:transport_call, _, _}
    end
  end

  test "SDK single-file posting preserves an explicit caption over payload text" do
    Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "post", "file_ids" => ["file"]}})
    [upload] = opts()[:files]
    payload = Jido.Chat.PostPayload.new(%{text: "Payload text", files: [upload]})
    options = opts() |> Keyword.delete(:files) |> Keyword.put(:caption, "Explicit caption")

    assert {:ok, response} = Jido.Chat.Adapter.post_message(Adapter, "room", payload, options)
    assert response.external_message_id == "post"
    assert_received {:transport_call, :upload_files, ["room", [_], _]}
    assert_received {:transport_call, :send_message, ["room", "Explicit caption", _]}
    refute_received {:transport_call, _, _}
  end

  for caption <- [nil, ""] do
    @blank_caption caption
    test "SDK single-file posting retains the text fallback with caption #{inspect(caption)}" do
      Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "post", "file_ids" => ["file"]}})
      [upload] = opts()[:files]
      payload = Jido.Chat.PostPayload.new(%{text: "Payload text", files: [upload]})

      for text_options <- [[], [text: "Explicit text"]] do
        options =
          opts()
          |> Keyword.delete(:files)
          |> Keyword.put(:caption, @blank_caption)
          |> Keyword.merge(text_options)

        expected_text = Keyword.get(text_options, :text, "Payload text")
        assert {:ok, response} = Jido.Chat.Adapter.post_message(Adapter, "room", payload, options)
        assert response.external_message_id == "post"
        assert_received {:transport_call, :upload_files, ["room", [_], _]}
        assert_received {:transport_call, :send_message, ["room", ^expected_text, _]}
        refute_received {:transport_call, _, _}
      end
    end
  end

  test "confirmed single-file delivery preserves caption, timestamp and upload metadata" do
    post = %{
      "id" => "post",
      "channel_id" => "room",
      "file_ids" => ["file"],
      "create_at" => 1_700_000_000_000,
      "user_id" => "author",
      "root_id" => "root"
    }

    Process.put({RecordingTransport, :send_message}, {:ok, post})
    [upload] = opts()[:files]
    options = opts() |> Keyword.put(:caption, "Caption") |> Keyword.put(:thread_id, "root")

    assert {:ok, response} = Adapter.send_file("room", upload, options)
    assert response.external_message_id == "post"
    assert response.external_room_id == "room"
    assert response.status == :sent
    assert response.raw == post
    assert response.timestamp == post["create_at"]
    assert response.metadata.source_author_id == "author"
    assert response.metadata.file_ids == ["file"]
    assert response.metadata.filename == upload.filename
    assert response.metadata.upload_kind == upload.kind
    assert response.metadata.upload == %{"file_infos" => [%{"id" => "file"}]}
    assert [attachment] = response.metadata.attachments
    assert attachment.url == "mattermost://file/file"
    assert_received {:transport_call, :upload_files, _}
    assert_received {:transport_call, :send_message, ["room", "Caption", forwarded]}
    assert forwarded[:file_ids] == ["file"]
    assert forwarded[:thread_id] == "root"
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

    restored =
      sent |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> Jido.Chat.SentMessage.from_map()

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
        sent |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> Jido.Chat.SentMessage.from_map()

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

  for operation <- [:post, :edit] do
    @sparse_operation operation
    test "#{operation} preserves each upload's details when multiple upload results contain only IDs" do
      files = [
        %FileUpload{data: "image", filename: "photo.png", media_type: "image/png", size_bytes: 5},
        %FileUpload{data: "audio!", filename: "voice.ogg", media_type: "audio/ogg", size_bytes: 6}
      ]

      Process.put(
        {RecordingTransport, :upload_files},
        {:ok, %{"file_infos" => [%{"id" => "image-id"}, %{"id" => "audio-id"}]}}
      )

      # The post orders the attachments differently from the upload response.
      post = {:ok, %{"id" => "post", "file_ids" => ["audio-id", "image-id"]}}
      Process.put({RecordingTransport, :send_message}, post)
      Process.put({RecordingTransport, :edit_message}, post)
      options = Keyword.put(opts(), :files, files)

      result =
        case @sparse_operation do
          :post -> Adapter.post_message("room", Jido.Chat.PostPayload.new(%{text: "Files", files: files}), options)
          :edit -> Adapter.edit_message("room", "post", "Files", options)
        end

      assert {:ok, response} = result
      assert response.metadata.file_ids == ["audio-id", "image-id"]
      assert_received {:transport_call, :upload_files, ["room", [image, audio], _]}
      assert image.filename == "photo.png"
      assert audio.filename == "voice.ogg"

      expected = [
        {"audio-id", "voice.ogg", "audio/ogg", 6, :audio},
        {"image-id", "photo.png", "image/png", 5, :image}
      ]

      for entries <- [response.metadata.media, response.metadata.attachments] do
        actual = Enum.map(entries, &{&1.metadata.file_id, &1.filename, &1.media_type, &1.size_bytes, &1.kind})
        assert actual == expected
      end
    end
  end

  test "multi-file metadata prefers server details and correlates duplicate filenames by upload order" do
    files = [
      %FileUpload{data: "image", filename: "same.bin", media_type: "image/png", size_bytes: 5},
      %FileUpload{data: "audio!", filename: "same.bin", media_type: "audio/ogg", size_bytes: 6}
    ]

    Process.put(
      {RecordingTransport, :upload_files},
      {:ok,
       %{
         "file_infos" => [
           %{"id" => "image-id", "name" => "server.jpg", "mime_type" => "image/jpeg", "size" => 42},
           %{"id" => "audio-id", "name" => nil, "mime_type" => nil, "size" => nil}
         ]
       }}
    )

    Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "post", "file_ids" => ["audio-id", "image-id"]}})
    payload = Jido.Chat.PostPayload.new(%{text: "Files", files: files})
    assert {:ok, response} = Adapter.post_message("room", payload, opts())

    assert [audio, image] = response.metadata.attachments

    assert {audio.metadata.file_id, audio.filename, audio.media_type, audio.size_bytes, audio.kind} ==
             {"audio-id", "same.bin", "audio/ogg", 6, :audio}

    assert {image.metadata.file_id, image.filename, image.media_type, image.size_bytes, image.kind} ==
             {"image-id", "server.jpg", "image/jpeg", 42, :image}
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

  defmodule SizedTransport do
    def upload_files(_channel, files, _opts) do
      send(self(), {:batch, files})

      case Process.get(:upload_failure) do
        nil ->
          infos = Enum.map(files, &%{"id" => &1.filename, "name" => &1.filename})
          infos = if Process.get(:sparse_file_infos), do: Enum.map(infos, &Map.take(&1, ["id"])), else: infos
          {:ok, %{"file_infos" => infos}}

        failure ->
          {:error, failure}
      end
    end

    def send_message(_channel, _text, opts) do
      count = Process.get(:sized_post_count, 0) + 1
      Process.put(:sized_post_count, count)
      send(self(), {:posted, opts[:file_ids]})
      send(self(), {:post_opts, opts})

      if Process.get(:fail_post_number) == count do
        {:error, :timeout}
      else
        {:ok, %{"id" => "post-#{count}", "file_ids" => opts[:file_ids], "root_id" => opts[:thread_id]}}
      end
    end

    def edit_message(_channel, id, _text, opts) do
      send(self(), {:edited, opts[:file_ids]})
      {:ok, %{"id" => id, "file_ids" => opts[:file_ids], "root_id" => Process.get(:edit_root_id)}}
    end
  end

  test "fifteen files return two confirmed posts through the SDK" do
    files = for i <- 1..15, do: %FileUpload{data: :binary.copy("x", 1024), filename: "#{i}.txt"}
    payload = Jido.Chat.Postable.text("All files", files: files)
    thread = Jido.Chat.Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})

    assert {:ok, sent} = Jido.Chat.Thread.post(thread, payload, transport: SizedTransport, max_file_size: 307_200)

    assert %{confirmation: :confirmed, messages: [first, second], failed_files: []} =
             sent.response.metadata.delivery_report

    assert first.message_id != second.message_id
    assert length(first.metadata.file_ids) == 10
    assert length(second.metadata.file_ids) == 5
    assert first.body == "All files"
    assert second.body == "Additional files (2/2)."
    assert sent.id == first.message_id
    assert_received {:batch, batch}
    assert length(batch) == 10
    assert_received {:batch, batch}
    assert length(batch) == 5
    refute_received {:batch, _}
  end

  for entry <- [Jido.Chat.Thread, Jido.Chat.ChannelRef], scenario <- [:split, :rejected] do
    @posting_entry entry
    @delivery_scenario scenario
    test "#{entry} handle contains only confirmed first-post files for #{scenario} delivery" do
      files =
        case @delivery_scenario do
          :split ->
            for i <- 1..15, do: %FileUpload{data: "x", filename: "#{i}.txt"}

          :rejected ->
            [
              %FileUpload{data: "x", filename: "valid.txt"},
              %FileUpload{data: :binary.copy("x", 1025), filename: "large.txt"}
            ]
        end

      target =
        case @posting_entry do
          Jido.Chat.Thread ->
            Jido.Chat.Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})

          Jido.Chat.ChannelRef ->
            Jido.Chat.ChannelRef.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_id: "room"})
        end

      assert {:ok, sent} =
               @posting_entry.post(target, Jido.Chat.Postable.text("files", files: files),
                 transport: SizedTransport,
                 max_file_size: 1024
               )

      report = sent.response.metadata.delivery_report
      [first | rest] = report.messages
      assert sent.id == first.message_id
      assert sent.attachments == first.metadata.attachments
      assert Enum.all?(sent.attachments, &is_nil(&1.data))

      restored =
        sent |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> Jido.Chat.SentMessage.from_map()

      assert restored.default_opts == Keyword.put(sent.default_opts, :transport, Atom.to_string(SizedTransport))
      assert Enum.map(restored.attachments, & &1.url) == Enum.map(sent.attachments, & &1.url)
      replacement = Jido.Chat.Postable.text("replacement", files: [%FileUpload{data: "new", filename: "new.txt"}])
      assert {:ok, edited} = Jido.Chat.SentMessage.edit(restored, replacement)
      assert edited.id == sent.id
      assert [attachment] = edited.attachments
      assert attachment.url == "mattermost://file/new.txt"

      case @delivery_scenario do
        :split ->
          assert length(sent.attachments) == 10
          assert [second] = rest
          assert length(second.metadata.attachments) == 5
          assert second.thread_id == first.message_id
          assert report.confirmation == :confirmed

        :rejected ->
          assert [attachment] = sent.attachments
          assert attachment.filename == "valid.txt"
          assert rest == []
          assert [%{filename: "large.txt", reason: :file_too_large}] = report.failed_files
          assert report.confirmation == :partial
      end
    end
  end

  for restored? <- [false, true] do
    @restore_partial_handle restored?
    test "replacement does not retain a stale partial delivery report with restored handle #{@restore_partial_handle}" do
      thread =
        Jido.Chat.Thread.new(%{id: "room", adapter: Adapter, adapter_name: :mattermost, external_room_id: "room"})

      files = [
        %FileUpload{data: "old", filename: "old.txt"},
        %FileUpload{data: String.duplicate("x", 11), filename: "oversized.txt"}
      ]

      assert {:ok, sent} =
               Jido.Chat.Thread.post(thread, Jido.Chat.Postable.text("Original", files: files),
                 transport: SizedTransport,
                 max_file_size: 10
               )

      assert %{confirmation: :partial, failed_files: [%{filename: "oversized.txt"}]} =
               sent.response.metadata.delivery_report

      sent =
        if @restore_partial_handle do
          sent
          |> Jido.Chat.SentMessage.to_map()
          |> Jason.encode!()
          |> Jason.decode!()
          |> Jido.Chat.SentMessage.from_map()
        else
          sent
        end

      replacement = Jido.Chat.Postable.text("Replacement", files: [%FileUpload{data: "new", filename: "new.txt"}])
      assert {:ok, edited} = Jido.Chat.SentMessage.edit(sent, replacement)
      assert edited.id == sent.id
      assert edited.metadata.file_ids == ["new.txt"]
      assert [%{filename: "new.txt", url: "mattermost://file/new.txt"}] = edited.attachments

      serialized = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!()

      # A single-post edit may clear the report or publish its current result.
      # Neither representation may retain the previous operation's failures/files.
      if report = serialized["metadata"]["delivery_report"] do
        assert report["confirmation"] == "confirmed"
        assert report["failed_files"] == []
        assert [message] = report["messages"]
        assert message["message_id"] == edited.id
        assert message["body"] == "Replacement"
        assert message["metadata"]["file_ids"] == ["new.txt"]
      end
    end
  end

  test "nine valid files are posted and the oversized file is reported" do
    files =
      for i <- 1..10,
          do: %FileUpload{data: :binary.copy("x", if(i == 6, do: 307_201, else: 1024)), filename: "#{i}.txt"}

    assert {:ok, response} =
             Adapter.post_message("room", Jido.Chat.PostPayload.new(%{files: files}),
               transport: SizedTransport,
               max_file_size: 307_200
             )

    assert %{confirmation: :partial, messages: [post], failed_files: [failure]} = response.metadata.delivery_report
    assert length(post.metadata.file_ids) == 9
    assert failure.filename == "6.txt"
    assert failure.reason == :file_too_large
    assert failure.size == 307_201
    assert_received {:batch, batch}
    assert length(batch) == 9
  end

  test "editing fifteen files updates the original and posts the remaining five in its thread" do
    files = for i <- 1..15, do: %FileUpload{data: "x", filename: "#{i}.txt"}

    assert {:ok, response} =
             Adapter.edit_message("room", "existing", "answer",
               files: files,
               transport: SizedTransport,
               max_file_size: 307_200
             )

    assert %{messages: [first, second], confirmation: :confirmed} = response.metadata.delivery_report
    assert first.action == :updated
    assert first.message_id == "existing"
    assert second.action == :created
    assert second.thread_id == "existing"
    assert_received {:edited, first_ids}
    assert length(first_ids) == 10
    assert_received {:posted, next_ids}
    assert length(next_ids) == 5
    assert_received {:post_opts, options}
    assert options[:thread_id] == "existing"
  end

  for requested_root <- [nil, "stale-root"] do
    @requested_root requested_root
    test "restored reply edits report and use the server root with requested root #{inspect(requested_root)}" do
      Process.put(:edit_root_id, "existing-root")
      defaults = [transport: SizedTransport, max_file_size: 1024]
      defaults = if @requested_root, do: Keyword.put(defaults, :thread_id, @requested_root), else: defaults

      sent =
        Jido.Chat.SentMessage.new(%{
          adapter: Adapter,
          response: %{external_message_id: "reply", external_room_id: "room"},
          default_opts: defaults
        })

      restored =
        sent |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> Jido.Chat.SentMessage.from_map()

      files = for i <- 1..15, do: %FileUpload{data: "x", filename: "#{i}.txt"}
      assert {:ok, edited} = Jido.Chat.SentMessage.edit(restored, Jido.Chat.Postable.text("replacement", files: files))
      assert edited.id == "reply"
      assert length(edited.attachments) == 10
      assert [first, second] = edited.response.metadata.delivery_report.messages
      assert first.action == :updated
      assert first.metadata.root_id == "existing-root"
      assert first.thread_id == "existing-root"
      assert second.thread_id == "existing-root"
      assert_received {:post_opts, options}
      assert options[:thread_id] == "existing-root"

      serialized = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode!() |> Jason.decode!()

      assert Enum.all?(
               serialized["response"]["metadata"]["delivery_report"]["messages"],
               &(&1["thread_id"] == "existing-root")
             )
    end
  end

  test "later failure returns confirmed messages and identifies unconfirmed and unattempted files" do
    Process.put(:fail_post_number, 2)
    files = for i <- 1..25, do: %FileUpload{data: "x", filename: "#{i}.txt"}

    assert {:ok, response} =
             Adapter.post_message("room", Jido.Chat.PostPayload.new(%{files: files}),
               transport: SizedTransport,
               max_file_size: 307_200
             )

    assert %{messages: [first], confirmation: :partial, failed_files: failures} = response.metadata.delivery_report
    assert length(first.metadata.file_ids) == 10
    assert Enum.count(failures, &(&1.reason == :timeout and &1.delivery == :unconfirmed)) == 10
    assert Enum.count(failures, &(&1.reason == :not_attempted and &1.delivery == :not_sent)) == 5
    assert Process.get(:sized_post_count) == 2
  end

  test "fifteen exact-limit files are passed to the transport in two post groups" do
    files = for i <- 1..15, do: %FileUpload{data: :binary.copy("x", 307_200), filename: "#{i}.txt"}

    assert {:ok, response} =
             Adapter.post_message("room", Jido.Chat.PostPayload.new(%{files: files}),
               transport: SizedTransport,
               max_file_size: 307_200,
               thread_id: "root"
             )

    assert %{messages: [first, second], confirmation: :confirmed} = response.metadata.delivery_report
    assert first.thread_id == "root"
    assert second.thread_id == "root"
    assert_received {:batch, first_batch}
    assert length(first_batch) == 10
    assert_received {:batch, second_batch}
    assert length(second_batch) == 5
    refute_received {:batch, _}
    assert_received {:posted, first_ids}
    assert length(first_ids) == 10
    assert_received {:posted, last_ids}
    assert length(last_ids) == 5
  end

  test "sparse results preserve per-file fallbacks for a transport-managed upload group" do
    Process.put(:sparse_file_infos, true)

    files = [
      %FileUpload{data: :binary.copy("i", 1024), filename: "image.png", media_type: "image/png", size_bytes: 1024},
      %FileUpload{data: :binary.copy("a", 1024), filename: "audio.ogg", media_type: "audio/ogg", size_bytes: 1024}
    ]

    payload = Jido.Chat.PostPayload.new(%{text: "Files", files: files})
    assert {:ok, response} = Adapter.post_message("room", payload, transport: SizedTransport, max_file_size: 1024)
    assert_received {:batch, [%{filename: "image.png"}, %{filename: "audio.ogg"}]}
    refute_received {:batch, _}

    assert Enum.map(
             response.metadata.attachments,
             &{&1.metadata.file_id, &1.filename, &1.media_type, &1.size_bytes, &1.kind}
           ) == [
             {"image.png", "image.png", "image/png", 1024, :image},
             {"audio.ogg", "audio.ogg", "audio/ogg", 1024, :audio}
           ]
  end

  test "file delivery requires valid size configuration before any upload" do
    upload = %FileUpload{data: "x", filename: "one.txt"}

    for {value, reason} <- [
          {nil, :missing_configuration},
          {0, :invalid_configuration},
          {-1, :invalid_configuration},
          {"300", :invalid_configuration}
        ] do
      options = [max_file_size: value, transport: SizedTransport]
      assert {:error, {^reason, :max_file_size}} = Adapter.send_file("room", upload, options)

      assert {:error, {^reason, :max_file_size}} =
               Adapter.edit_message("room", "post", "", Keyword.put(options, :files, [upload]))
    end

    refute_received {:batch, _}
  end

  test "all files for one post or edit are passed together to the selected transport" do
    files = for i <- 1..10, do: %FileUpload{data: :binary.copy("x", 290 * 1024), filename: "#{i}.txt"}
    payload = Jido.Chat.PostPayload.new(%{text: "files", files: files})
    options = [transport: SizedTransport, max_file_size: 300 * 1024]

    for mode <- [:post, :edit] do
      result =
        if mode == :post,
          do: Adapter.post_message("room", payload, options),
          else: Adapter.edit_message("room", "post", "files", Keyword.put(options, :files, files))

      assert {:ok, response} = result
      assert length(response.metadata.file_ids) == 10
      assert_received {:batch, batch}
      assert length(batch) == 10
      refute_received {:batch, _}
    end

    assert_received {:posted, ids}
    assert length(ids) == 10
    assert_received {:edited, ^ids}
  end

  test "small files share a batch but oversized and unreadable files fail before upload" do
    options = [transport: SizedTransport, max_file_size: 1024]
    files = for i <- 1..10, do: %FileUpload{data: "x", filename: "#{i}.txt"}
    assert {:ok, _} = Adapter.post_message("room", Jido.Chat.PostPayload.new(%{files: Enum.take(files, 2)}), options)
    assert_received {:batch, [_, _]}
    assert_received {:posted, _}
    oversized = %FileUpload{data: :binary.copy("x", 1025), filename: "large.txt", size_bytes: 1}
    assert {:error, {:file_too_large, %{size: 1025, limit: 1024}}} = Adapter.send_file("room", oversized, options)

    assert {:error, {:file_read_error, :enoent}} =
             Adapter.send_file("room", %FileUpload{path: "/nonexistent/limit-test.txt"}, options)

    refute_received {:batch, _}
    refute_received {:posted, _}
  end

  test "an exact-limit file reaches the selected transport and failures never post" do
    options = [transport: SizedTransport, max_file_size: 1024]
    file = %FileUpload{data: :binary.copy("x", 1024), filename: "exact.txt"}
    assert {:ok, _} = Adapter.send_file("room", file, options)
    assert_received {:batch, [_]}
    assert_received {:posted, _}
    Process.put(:upload_failure, :timeout)
    assert {:error, :timeout} = Adapter.send_file("room", file, options)
    refute_received {:posted, _}
  end

  test "custom transports are not constrained by Req multipart header sizes" do
    upload = %FileUpload{data: "x", filename: String.duplicate("long", 300) <> ".txt"}
    options = [transport: SizedTransport, max_file_size: 1]
    assert {:ok, _} = Adapter.send_file("room", upload, options)
    assert_received {:batch, [%{filename: filename}]}
    assert filename == upload.filename
    assert_received {:posted, [^filename]}

    files = [upload, %FileUpload{data: "y", filename: "short.txt"}]
    assert {:ok, _} = Adapter.post_message("room", Jido.Chat.PostPayload.new(%{files: files}), options)
    assert_received {:batch, [_, _]}
  end

  defp opts do
    [
      max_file_size: 307_200,
      transport: RecordingTransport,
      token: "test-token",
      files: [
        %FileUpload{kind: :file, data: <<0, 255>>, filename: "file.png", media_type: "image/png"}
      ]
    ]
  end
end
