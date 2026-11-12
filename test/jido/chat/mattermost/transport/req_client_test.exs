defmodule Jido.Chat.Mattermost.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  # Integration tests for the real HTTP client.
  # Excluded by default; CI bootstraps an ephemeral server and includes this tag.
  @moduletag :integration

  @url System.get_env("MATTERMOST_URL", "")
  @token System.get_env("MATTERMOST_TOKEN", "")
  @channel_id System.get_env("MATTERMOST_CHANNEL_ID", "")
  @file_id System.get_env("MATTERMOST_FILE_ID", "")

  alias Jido.Chat.Mattermost.Transport.ReqClient
  alias Jido.Chat.Mattermost.Adapter

  defp opts,
    do: [
      url: @url,
      token: @token,
      max_file_size: String.to_integer(System.get_env("MATTERMOST_MAX_FILE_SIZE", "307200"))
    ]

  test "invalid authentication is preserved across writes, uploads, downloads, and typing" do
    post = create_post("authentication failure target")
    invalid_opts = Keyword.put(opts(), :token, Base.encode16(:crypto.strong_rand_bytes(24)))

    for {callback, args} <- [
          {:send_message, [@channel_id, "unauthorized"]},
          {:edit_message, [@channel_id, post["id"], "unauthorized"]},
          {:upload_files, [@channel_id, [%{body: "bytes", filename: "unauthorized.txt"}]]},
          {:upload_files, [@channel_id, [%{body: "one", filename: "one.txt"}, %{body: "two", filename: "two.txt"}]]},
          {:download_file, [@file_id]},
          {:add_reaction, [post["id"], "thumbsup"]},
          {:send_typing, [@channel_id]}
        ] do
      assert {:error, {401, body}} = apply(ReqClient, callback, args ++ [invalid_opts])
      assert is_map(body) or is_binary(body)
    end

    assert {:ok, unchanged} = ReqClient.fetch_post(post["id"], opts())
    assert unchanged["message"] == "authentication failure target"
  end

  test "policy HTTP failures are neutral for uploads and final publication" do
    post = create_post("policy authentication failure target")
    invalid_opts = Keyword.put(opts(), :token, Base.encode16(:crypto.strong_rand_bytes(24)))

    for policy <- [:abort, :continue] do
      policy_opts = Keyword.put(invalid_opts, :attachment_failure_policy, policy)
      assert {:error, {:http_error, 401}} = ReqClient.send_message(@channel_id, "unauthorized", policy_opts)

      assert {:error, {:http_error, 401}} =
               ReqClient.edit_message(@channel_id, post["id"], "unauthorized", policy_opts)

      assert {:error, {:partial_upload, %{reason: {:http_error, 401}, uploaded: %{"file_infos" => []}}}} =
               ReqClient.upload_files(@channel_id, [%{body: "bytes", filename: "unauthorized.txt"}], policy_opts)

      assert {:ok, unchanged} = ReqClient.fetch_post(post["id"], opts())
      assert unchanged["message"] == "policy authentication failure target"
    end
  end

  test "downloading a nonexistent file preserves its HTTP error" do
    missing_id = String.duplicate("0", 26)
    assert {:error, {404, body}} = ReqClient.download_file(missing_id, opts())
    assert is_binary(body)
  end

  @tag timeout: 120_000
  @tag capture_log: true
  test "network errors propagate through every HTTP request helper" do
    # Obtain an OS-assigned local port, then close it to exercise real connection failures.
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    unavailable_opts = Keyword.put(opts(), :url, "http://127.0.0.1:#{port}")

    for {callback, args} <- [
          {:fetch_post, ["p1"]},
          {:send_message, [@channel_id, "unreachable"]},
          {:edit_message, [@channel_id, "p1", "unreachable"]},
          {:delete_message, [@channel_id, "p1"]},
          {:upload_files, [@channel_id, [%{body: "bytes", filename: "unreachable.txt"}]]},
          {:upload_files, [@channel_id, [%{body: "one", filename: "one.txt"}, %{body: "two", filename: "two.txt"}]]},
          {:download_file, [@file_id]}
        ] do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               apply(ReqClient, callback, args ++ [unavailable_opts])
    end
  end

  test "application defaults and per-call precedence work in an isolated VM" do
    script = ~S"""
    import ExUnit.Assertions
    alias Jido.Chat.Mattermost.Transport.ReqClient
    {:ok, _} = Application.ensure_all_started(:req)
    url = System.fetch_env!("MATTERMOST_URL")
    token = System.fetch_env!("MATTERMOST_TOKEN")
    id = System.fetch_env!("MATTERMOST_CHANNEL_ID")

    Application.put_env(:jido_chat_mattermost, :url, url)
    Application.put_env(:jido_chat_mattermost, :token, token)
    assert {:ok, %{"id" => ^id}} = ReqClient.fetch_channel(id, [])

    Application.put_env(:jido_chat_mattermost, :url, "http://127.0.0.1:1")
    Application.put_env(:jido_chat_mattermost, :token, "invalid")
    assert {:ok, %{"id" => ^id}} = ReqClient.fetch_channel(id, url: url, token: token)
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]
    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, String.replace(output, @token, "[REDACTED]")
  end

  test "the adapter defaults to ReqClient when no transport is selected" do
    assert {:ok, response} = Jido.Chat.Mattermost.Adapter.send_message(@channel_id, "default transport", opts())
    post_id = response.external_message_id
    on_exit(fn -> ReqClient.delete_message(@channel_id, post_id, opts()) end)
    assert {:ok, post} = ReqClient.fetch_post(post_id, opts())
    assert post["message"] == "default transport"
    assert post["channel_id"] == @channel_id
  end

  defp create_post(text, extra_opts \\ []) do
    assert {:ok, post} = ReqClient.send_message(@channel_id, text, opts() ++ extra_opts)
    on_exit(fn -> ReqClient.delete_message(@channel_id, post["id"], opts()) end)
    post
  end

  defp reactions(post_id) do
    # Read-only verification endpoint; production reaction writes still use ReqClient.
    {:ok, response} =
      Req.get(@url <> "/api/v4/posts/#{post_id}/reactions",
        headers: [{"Authorization", "Bearer #{@token}"}]
      )

    assert response.status == 200
    # Mattermost returns JSON null rather than [] when the last reaction is removed.
    assert is_nil(response.body) or is_list(response.body)
    response.body || []
  end

  test "send_message/3 creates a post" do
    post = create_post("req_client_test #{DateTime.utc_now()}")

    assert is_binary(post["id"])
    assert post["channel_id"] == @channel_id
  end

  test "fetch_posts/2 returns channel posts" do
    assert {:ok, result} = ReqClient.fetch_posts(@channel_id, Keyword.put(opts(), :limit, 5))
    assert is_map(result)
  end

  test "fetch_channel/2 returns channel metadata" do
    assert {:ok, channel} = ReqClient.fetch_channel(@channel_id, opts())
    assert is_binary(channel["id"])
  end

  test "download_file/2 returns attachment bytes" do
    assert {:ok, bytes} = ReqClient.download_file(@file_id, opts())
    assert is_binary(bytes) and byte_size(bytes) > 0
  end

  test "message lifecycle sends, fetches, edits, and deletes a post" do
    post = create_post("message lifecycle")
    post_id = post["id"]

    assert {:ok, fetched} = ReqClient.fetch_post(post_id, opts())
    assert fetched["message"] == "message lifecycle"
    assert fetched["channel_id"] == @channel_id

    assert {:ok, edited} = ReqClient.edit_message(@channel_id, post_id, "updated message", opts())
    assert edited["id"] == post_id
    assert edited["message"] == "updated message"
    assert {:ok, fetched} = ReqClient.fetch_post(post_id, opts())
    assert fetched["message"] == "updated message"

    assert {:ok, _} = ReqClient.delete_message(@channel_id, post_id, opts())
    assert {:error, {404, _}} = ReqClient.fetch_post(post_id, opts())
  end

  test "thread replies reference their root and appear in the fetched thread" do
    root = create_post("thread root")
    reply = create_post("thread reply", thread_id: root["id"])

    assert reply["root_id"] == root["id"]
    assert {:ok, thread} = ReqClient.fetch_thread(root["id"], opts())
    assert MapSet.new(thread["order"]) == MapSet.new([root["id"], reply["id"]])
    assert thread["posts"][root["id"]]["message"] == "thread root"
    assert thread["posts"][reply["id"]]["message"] == "thread reply"
    assert thread["posts"][reply["id"]]["root_id"] == root["id"]
  end

  test "reactions resolve the authenticated user, accept an explicit user, and can be removed" do
    post = create_post("reaction target")
    assert {:ok, user} = ReqClient.get_user("me", opts())
    user_id = user["id"]

    for reaction_opts <- [opts(), Keyword.put(opts(), :user_id, user_id)] do
      assert {:ok, reaction} = ReqClient.add_reaction(post["id"], "thumbsup", reaction_opts)
      assert reaction["post_id"] == post["id"]
      assert reaction["user_id"] == user_id
      assert reaction["emoji_name"] == "thumbsup"

      assert Enum.any?(reactions(post["id"]), fn item ->
               item["user_id"] == user_id and item["emoji_name"] == "thumbsup"
             end)

      assert {:ok, _} = ReqClient.remove_reaction(post["id"], "thumbsup", user_id, opts())
      refute Enum.any?(reactions(post["id"]), &(&1["emoji_name"] == "thumbsup"))
    end
  end

  test "the server accepts a typing notification" do
    assert :ok = ReqClient.send_typing(@channel_id, opts())
  end

  @tag :tmp_dir
  test "path-backed and byte-backed uploads attach, replace on the same post, and download unchanged", %{
    tmp_dir: tmp_dir
  } do
    bytes = <<0, 1, 2, 127, 128, 254, 255>> <> "Mattermost binary attachment\n"
    path = Path.join(tmp_dir, "path-fixture.bin")
    File.write!(path, bytes)

    for {file, expected_name} <- [
          {%{path: path}, "path-fixture.bin"},
          {%{body: bytes, filename: "bytes-fixture.bin", content_type: "application/octet-stream"}, "bytes-fixture.bin"}
        ] do
      assert {:ok, uploaded} = ReqClient.upload_files(@channel_id, [file], opts())
      assert [info] = uploaded["file_infos"]
      assert info["name"] == expected_name
      assert info["size"] == byte_size(bytes)

      post = create_post("uploaded attachment", file_ids: [info["id"]])
      assert post["file_ids"] == [info["id"]]
      assert {:ok, fetched} = ReqClient.fetch_post(post["id"], opts())
      assert fetched["file_ids"] == [info["id"]]
      assert {:ok, ^bytes} = ReqClient.download_file(info["id"], opts())

      replacement_bytes = "replacement:" <> bytes
      replacement = %{body: replacement_bytes, filename: "replacement.bin", content_type: "application/octet-stream"}
      assert {:ok, %{"file_infos" => [replacement_info]}} = ReqClient.upload_files(@channel_id, [replacement], opts())
      replacement_id = replacement_info["id"]
      refute replacement_id == info["id"]

      assert {:ok, edited} =
               ReqClient.edit_message(
                 @channel_id,
                 post["id"],
                 "replaced attachment",
                 Keyword.put(opts(), :file_ids, [replacement_id])
               )

      assert edited["id"] == post["id"]
      assert edited["channel_id"] == @channel_id
      assert edited["file_ids"] == [replacement_id]
      assert {:ok, fetched} = ReqClient.fetch_post(post["id"], opts())
      assert fetched["file_ids"] == [replacement_id]
      # A successful edit response alone does not guarantee the file has a valid channel.
      assert {:ok, ^replacement_bytes} = ReqClient.download_file(replacement_id, opts())
    end

    for owner <- [Jido.Chat.Thread, Jido.Chat.ChannelRef] do
      handle =
        owner.new(%{
          id: "integration",
          adapter_name: :mattermost,
          adapter: Adapter,
          external_room_id: @channel_id,
          external_id: @channel_id
        })

      files = [
        %Jido.Chat.FileUpload{path: path},
        %Jido.Chat.FileUpload{data: "second file", filename: "second.txt"}
      ]

      assert {:ok, sent} = owner.post(handle, Jido.Chat.Postable.text("Two files", files: files), opts())
      on_exit(fn -> ReqClient.delete_message(@channel_id, sent.id, opts()) end)
      assert length(sent.response.metadata.file_ids) == 2
      assert {:ok, post} = ReqClient.fetch_post(sent.id, opts())
      assert post["file_ids"] == sent.response.metadata.file_ids

      expected_files = %{"path-fixture.bin" => bytes, "second.txt" => "second file"}

      for media <- sent.response.metadata.media do
        expected = Map.fetch!(expected_files, media.filename)
        assert {:ok, ^expected} = Adapter.fetch_media(media, opts())
      end

      replacements = [
        %Jido.Chat.FileUpload{data: "new first", filename: "new-first.txt"},
        %Jido.Chat.FileUpload{data: <<0, 255, 128>>, filename: "new-second.bin"}
      ]

      restored =
        sent |> Jido.Chat.SentMessage.to_map() |> Map.put("default_opts", []) |> Jido.Chat.SentMessage.from_map()

      assert {:ok, edited} =
               Jido.Chat.SentMessage.edit(
                 restored,
                 Jido.Chat.Postable.text("Two replacements", files: replacements),
                 opts()
               )

      assert edited.id == sent.id
      assert length(edited.attachments) == 2
      assert {:ok, post} = ReqClient.fetch_post(sent.id, opts())
      assert post["file_ids"] == edited.metadata.file_ids
      refute Enum.any?(post["file_ids"], &(&1 in sent.response.metadata.file_ids))

      expected_files = %{"new-first.txt" => "new first", "new-second.bin" => <<0, 255, 128>>}

      for media <- edited.metadata.media do
        expected = Map.fetch!(expected_files, media.filename)
        assert {:ok, ^expected} = Adapter.fetch_media(media, opts())
      end

      assert {:ok, _} = edited |> Jido.Chat.SentMessage.to_map() |> Jason.encode()
      assert {:ok, text_edited} = Jido.Chat.SentMessage.edit(edited, "Text only", opts())
      assert MapSet.new(text_edited.metadata.file_ids) == MapSet.new(edited.metadata.file_ids)
      assert text_edited.metadata.file_ids == text_edited.response.raw["file_ids"]
      assert MapSet.new(text_edited.attachments, & &1.filename) == MapSet.new(["new-first.txt", "new-second.bin"])
    end
  end

  @tag :tmp_dir
  test "transport batches exact-limit uploads and returns ordered results for one post", %{tmp_dir: tmp_dir} do
    limit = opts()[:max_file_size]
    first_bytes = :binary.copy("a", limit)
    second_bytes = :binary.copy("b", limit)
    path = Path.join(tmp_dir, "second.txt")
    File.write!(path, second_bytes)

    files = [
      %{body: first_bytes, filename: "first.txt", content_type: "text/plain"},
      %{path: path, filename: "second.txt", content_type: "text/plain"},
      %{body: "last", filename: "third.txt", content_type: "text/plain"}
    ]

    assert {:ok, %{"file_infos" => infos}} = ReqClient.upload_files(@channel_id, files, opts())
    assert Enum.map(infos, & &1["name"]) == ["first.txt", "second.txt", "third.txt"]
    assert Enum.map(infos, & &1["size"]) == [limit, limit, 4]
    ids = Enum.map(infos, & &1["id"])
    assert length(Enum.uniq(ids)) == 3
    post = create_post("transport-managed upload batches", file_ids: ids)
    assert {:ok, fetched} = ReqClient.fetch_post(post["id"], opts())
    # Mattermost may reorder attachments when persisting the post. Upload results
    # must preserve input order, but the saved post only needs every uploaded ID.
    assert Enum.sort(fetched["file_ids"]) == Enum.sort(ids)

    for {id, bytes} <- Enum.zip(ids, [first_bytes, second_bytes, "last"]) do
      assert {:ok, ^bytes} = ReqClient.download_file(id, opts())
    end
  end

  @tag :tmp_dir
  test "JPEG, PNG, GIF, WebP, and documents retain file-info MIME and original bytes", %{tmp_dir: tmp_dir} do
    fixtures =
      __DIR__
      |> Path.join("../../../../fixtures/media.json")
      |> File.read!()
      |> Jason.decode!()

    for fixture <- fixtures,
        source <- [:path, :bytes] do
      %{"filename" => filename, "media_type" => media_type, "kind" => kind, "base64" => encoded} = fixture
      file_info_media_type = Map.get(fixture, "file_info_media_type", media_type)
      bytes = Base.decode64!(encoded)
      path = Path.join(tmp_dir, filename)
      File.write!(path, bytes)

      file =
        case source do
          :path -> %{path: path}
          :bytes -> %{body: bytes, filename: filename, content_type: media_type}
        end

      assert {:ok, %{"file_infos" => [info]}} = ReqClient.upload_files(@channel_id, [file], opts())
      assert info["name"] == filename
      assert info["mime_type"] == file_info_media_type
      assert info["size"] == byte_size(bytes)

      post = create_post("MIME audit #{filename} #{source}", file_ids: [info["id"]])
      assert {:ok, fetched} = ReqClient.fetch_post(post["id"], opts())
      assert [fetched_info] = fetched["metadata"]["files"]
      assert fetched_info["id"] == info["id"]
      assert fetched_info["mime_type"] == file_info_media_type

      assert {:ok, incoming} = Adapter.transform_incoming(%{"post" => fetched})
      assert [media] = incoming.media
      assert media.media_type == media_type
      assert Atom.to_string(media.kind) == kind
      assert media.metadata.file_id == info["id"]
      assert {:ok, ^bytes} = Adapter.fetch_media(media, opts())
    end
  end

  describe "local connection failures" do
    @describetag :local_connection
    @describetag capture_log: true

    setup do
      # A real refused connection exercises Req's error boundary without HTTP mocks
      # or a running Mattermost instance.
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      {:ok, opts: [url: "http://127.0.0.1:#{port}", token: System.get_env("MATTERMOST_TOKEN", ""), max_file_size: 1024]}
    end

    for operation <- [:upload, :send, :edit] do
      @operation operation

      test "#{operation} returns neutral policy connection failures and preserves legacy errors", %{opts: opts} do
        for policy <- [:continue, :abort] do
          result = invoke_refused_connection(@operation, Keyword.put(opts, :attachment_failure_policy, policy))

          if @operation == :upload do
            assert {:error, {:partial_upload, %{reason: :econnrefused, uploaded: %{"file_infos" => []}}}} = result
          else
            assert {:error, :econnrefused} = result
          end
        end

        assert {:error, %Req.TransportError{reason: :econnrefused}} = invoke_refused_connection(@operation, opts)
      end
    end
  end

  defp invoke_refused_connection(:upload, opts),
    do: ReqClient.upload_files("room", [%{body: "bytes", filename: "file.txt"}], opts)

  defp invoke_refused_connection(:send, opts), do: ReqClient.send_message("room", "Answer", opts)
  defp invoke_refused_connection(:edit, opts), do: ReqClient.edit_message("room", "post", "Answer", opts)
end
