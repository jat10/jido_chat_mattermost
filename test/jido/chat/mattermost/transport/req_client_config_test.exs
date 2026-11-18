defmodule Jido.Chat.Mattermost.Transport.ReqClientConfigTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Transport.ReqClient

  describe "local connection failures" do
    @describetag timeout: 120_000
    @describetag capture_log: true

    setup do
      # Close an OS-assigned local port to exercise Req's real error boundary.
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      {:ok,
       opts: [
         url: "http://127.0.0.1:#{port}",
         token: System.get_env("MATTERMOST_TOKEN", ""),
         max_file_size: 1024
       ]}
    end

    for {name, callback, args, extra_opts} <- [
          {"single upload", :upload_files, ["room", [%{body: "bytes", filename: "file.txt"}]], []},
          {"multiple uploads", :upload_files,
           ["room", [%{body: "one", filename: "one.txt"}, %{body: "two", filename: "two.txt"}]], []},
          {"send", :send_message, ["room", "Answer"], [thread_id: "root-post"]},
          {"edit", :edit_message, ["room", "post", "Answer"], []},
          {"fetch post", :fetch_post, ["post"], []},
          {"delete", :delete_message, ["room", "post"], []},
          {"download", :download_file, ["file"], []},
          {"fetch posts with limit", :fetch_posts, ["room"], [limit: 5]},
          {"fetch posts before", :fetch_posts, ["room"], [before: "post"]},
          {"fetch posts after", :fetch_posts, ["room"], [after: "post"]},
          {"fetch thread", :fetch_thread, ["post"], []},
          {"fetch channel", :fetch_channel, ["room"], []},
          {"get user", :get_user, ["user"], []},
          {"list teams", :list_teams, [], []},
          {"list public channels", :list_public_channels, ["team"], []},
          {"add reaction with user lookup", :add_reaction, ["post", "thumbsup"], []},
          {"add reaction with supplied user", :add_reaction, ["post", "thumbsup"], [user_id: "user"]},
          {"remove reaction", :remove_reaction, ["post", "thumbsup", "user"], []},
          {"typing", :send_typing, ["room"], []},
          {"open DM", :open_dm_channel, ["bot", "user"], []}
        ] do
      @operation callback
      @args args
      @extra_opts extra_opts

      test "#{name} preserves the connection failure contract", %{opts: opts} do
        result = apply(ReqClient, @operation, @args ++ [Keyword.merge(opts, @extra_opts)])

        if @operation in [:send_message, :edit_message, :upload_files] do
          assert {:error, :econnrefused} = result
        else
          assert {:error, %Req.TransportError{reason: :econnrefused}} = result
        end
      end
    end
  end

  test "configuration resolves without an upload-request setting in an isolated VM" do
    script = ~S"""
    import ExUnit.Assertions
    alias Jido.Chat.Mattermost.Transport.ReqClient

    Application.delete_env(:jido_chat_mattermost, :url)
    Application.delete_env(:jido_chat_mattermost, :token)
    Application.delete_env(:jido_chat_mattermost, :max_upload_request_size)
    Application.delete_env(:jido_chat_mattermost, :max_file_size)

    alias Jido.Chat.Mattermost.{Adapter, EditOptions, SendOptions}
    files = [%{data: "bytes", filename: "file.txt"}]
    assert {:ok, %{max_file_size: :unresolved, max_upload_request_size: :not_applicable}} =
             Jido.Chat.Adapter.file_requirements(Adapter)
    assert {:error, {:missing_configuration, :max_file_size}} = Adapter.prepare_upload("room", files)
    assert {:ok, prepared} = Jido.Chat.Adapter.prepare_upload(Adapter, "room", files, max_file_size: 5)
    assert prepared.size_bytes == byte_size(prepared.body)
    assert prepared.size_bytes > 5

    Application.put_env(:jido_chat_mattermost, :max_file_size, 4)
    Application.put_env(:jido_chat_mattermost, :max_upload_request_size, 0)
    assert {:error, {:file_too_large, %{size: 5, limit: 4}}} = Adapter.prepare_upload("room", files)
    assert {:ok, %{max_file_size: 4, max_upload_request_size: :not_applicable}} = Adapter.file_requirements()
    assert {:ok, _} = Adapter.prepare_upload("room", files, max_file_size: 5, max_upload_request_size: 1)

    for module <- [SendOptions, EditOptions] do
      options = module.new(max_upload_request_size: 1)
      refute Map.has_key?(options, :max_upload_request_size)
      refute Keyword.has_key?(module.transport_opts(options), :max_upload_request_size)
    end

    assert_raise RuntimeError, ~r/Mattermost URL not configured/, fn ->
      ReqClient.fetch_channel("c1", [])
    end

    assert_raise RuntimeError, ~r/Mattermost token not configured/, fn ->
      ReqClient.fetch_channel("c1", url: "http://localhost:8065")
    end
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]
    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
  end

  test "unusable upload sources fail without making a request" do
    for file <- [%{}, %{path: ""}, %{body: ""}, %{body: "bytes"}, %{body: "bytes", filename: ""}] do
      assert {:error, :missing_file_source} = ReqClient.upload_files("c1", [file], [])
    end

    assert {:error, :missing_file_source} = ReqClient.upload_files("c1", [], [])
  end

  test "upload and publication exceptions are always neutral without policy" do
    opts = [url: "", token: "test-token"]
    file = %{body: "bytes", filename: "file.txt"}
    assert {:error, :transport_exception} = ReqClient.upload_files("room", [file], opts)
    assert {:error, :transport_exception} = ReqClient.send_message("room", "Answer", opts)
    assert {:error, :transport_exception} = ReqClient.edit_message("room", "post", "Answer", opts)
  end

  test "exact multipart preparation preserves the complete candidate and ordered metadata without a ceiling" do
    files = [%{body: "bytes", filename: "file.txt", content_type: "text/plain"}, %{body: "two", filename: "second.txt"}]
    assert {:ok, prepared} = ReqClient.prepare_upload("room", files, [])
    assert prepared.channel_id == "room"
    assert prepared.size_bytes == byte_size(prepared.body)

    assert prepared.files == [
             %{filename: "file.txt", content_type: "text/plain", size_bytes: 5},
             %{filename: "second.txt", size_bytes: 3}
           ]

    assert prepared.body =~ "bytes"
    assert prepared.body =~ "second.txt"
    assert prepared.body =~ "name=\"channel_id\"\r\n\r\nroom"
    assert prepared.content_type =~ "multipart/form-data; boundary="
    boundary = String.split(prepared.content_type, "boundary=") |> List.last()
    assert String.ends_with?(prepared.body, "--#{boundary}--\r\n")

    assert {:ok, repeated} = ReqClient.prepare_upload("room", files, [])
    assert repeated.size_bytes == prepared.size_bytes
  end

  test "header-heavy and larger candidates remain whole without an inferred request ceiling" do
    for files <- [
          [%{body: "x", filename: String.duplicate("long", 1000)}],
          [%{body: String.duplicate("x", 2048), filename: "large.txt"}],
          [%{body: "x", filename: "small.txt"}, %{body: "x", filename: String.duplicate("long", 1000)}]
        ] do
      assert {:ok, prepared} = ReqClient.prepare_upload("room", files, max_file_size: 2048)
      assert prepared.size_bytes == byte_size(prepared.body)
      assert prepared.size_bytes > 2048
      assert Enum.map(prepared.files, & &1.filename) == Enum.map(files, & &1.filename)
      assert Enum.all?(files, &String.contains?(prepared.body, &1.body))
    end
  end

  test "retired request configuration cannot block preparation or transport execution" do
    file = %{body: "x", filename: "file.txt"}

    for limit <- [nil, 0, -1, "10", 1] do
      opts = [max_upload_request_size: limit, url: "", token: "test-token"]
      assert {:ok, prepared} = ReqClient.prepare_upload("room", [file], opts)
      assert {:error, :transport_exception} = ReqClient.upload_prepared(prepared, opts)
    end
  end

  test "empty candidates and malformed prepared representations never reach HTTP" do
    for files <- [[], nil, :invalid] do
      assert {:error, :missing_file_source} = ReqClient.prepare_upload("room", files, [])
    end

    for prepared <- [%{}, %{body: "bytes", content_type: "multipart/form-data", size_bytes: 4, files: [%{}]}] do
      assert {:error, :invalid_prepared_upload} = ReqClient.upload_prepared(prepared, [])
    end
  end

  @tag :tmp_dir
  test "pure preparation never reads paths and convenience uploads contain missing-file errors", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing.txt")

    assert {:error, :file_not_materialized} =
             ReqClient.prepare_upload("room", [%{path: path}], [])

    assert {:error, :file_unavailable} = ReqClient.upload_files("room", [%{path: path}], [])
    File.write!(path, "bytes")

    assert {:error, :file_not_materialized} =
             ReqClient.prepare_upload("room", [%{path: path}], [])

    assert {:error, :transport_exception} =
             ReqClient.upload_files("room", [%{path: path}],
               url: "",
               token: "test-token"
             )
  end
end
