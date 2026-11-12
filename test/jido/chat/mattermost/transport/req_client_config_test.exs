defmodule Jido.Chat.Mattermost.Transport.ReqClientConfigTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Transport.ReqClient

  test "missing URL and token produce descriptive errors in an isolated VM" do
    script = ~S"""
    import ExUnit.Assertions
    alias Jido.Chat.Mattermost.Transport.ReqClient

    Application.delete_env(:jido_chat_mattermost, :url)
    Application.delete_env(:jido_chat_mattermost, :token)

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
      assert {:error, :missing_file_source} =
               Jido.Chat.Mattermost.Transport.ReqClient.upload_files("c1", [file], [])
    end

    assert {:error, :missing_file_source} =
             Jido.Chat.Mattermost.Transport.ReqClient.upload_files("c1", [], [])
  end

  test "policy uploads report invalid URL configuration without claiming a confirmed upload" do
    file = %{body: "bytes", filename: "file.txt"}
    opts = [url: "", token: "test-token", max_file_size: 1024]

    for policy <- [:abort, :continue] do
      assert {:error, {:partial_upload, %{reason: :transport_exception, uploaded: %{"file_infos" => []}}}} =
               Jido.Chat.Mattermost.Transport.ReqClient.upload_files(
                 "room",
                 [file],
                 Keyword.put(opts, :attachment_failure_policy, policy)
               )
    end

    assert_raise ArgumentError, fn ->
      Jido.Chat.Mattermost.Transport.ReqClient.upload_files("room", [file], opts)
    end
  end

  test "policy publication exceptions use neutral errors and legacy calls still raise" do
    opts = [url: "", token: "test-token"]

    for policy <- [:abort, :continue] do
      policy_opts = Keyword.put(opts, :attachment_failure_policy, policy)

      assert {:error, :transport_exception} =
               Jido.Chat.Mattermost.Transport.ReqClient.send_message("room", "Answer", policy_opts)

      assert {:error, :transport_exception} =
               Jido.Chat.Mattermost.Transport.ReqClient.edit_message("room", "post", "Answer", policy_opts)
    end

    assert_raise ArgumentError, fn -> Jido.Chat.Mattermost.Transport.ReqClient.send_message("room", "Answer", opts) end

    assert_raise ArgumentError, fn ->
      Jido.Chat.Mattermost.Transport.ReqClient.edit_message("room", "post", "Answer", opts)
    end
  end

  @tag :tmp_dir
  test "path-backed upload batches are fully sized before making a request", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file.txt")
    File.write!(path, "bytes")
    long_header = %{body: "bytes", filename: String.duplicate("long", 1000) <> ".txt"}

    assert {:error, :upload_request_too_large} =
             Jido.Chat.Mattermost.Transport.ReqClient.upload_files(
               "room",
               [%{path: path}, %{body: "bytes", filename: "second.txt"}, long_header],
               max_file_size: 1024
             )
  end

  test "upload sizing rejects missing or invalid limits before making a request" do
    file = %{body: "x", filename: "file.txt"}

    for {limit, reason} <- [
          {nil, :missing_configuration},
          {0, :invalid_configuration},
          {-1, :invalid_configuration},
          {"10", :invalid_configuration}
        ] do
      assert {:error, {^reason, :max_file_size}} =
               Jido.Chat.Mattermost.Transport.ReqClient.upload_files("room", [file], max_file_size: limit)
    end
  end

  test "multipart overhead is checked for every file before any upload" do
    file = %{body: "x", filename: "small.txt"}
    long_header = %{body: "x", filename: String.duplicate("long", 1000) <> ".txt"}

    # No URL or token: reaching HTTP before planning the later file would raise.
    assert {:error, :upload_request_too_large} =
             Jido.Chat.Mattermost.Transport.ReqClient.upload_files("room", [file, long_header], max_file_size: 1024)
  end

  describe "multipart preparation failures" do
    for policy <- [:abort, :continue] do
      @policy policy

      @tag :tmp_dir
      test "#{policy} returns a neutral error when a path is missing during multipart preparation", %{tmp_dir: tmp_dir} do
        path = Path.join(tmp_dir, "missing.txt")
        refute File.exists?(path)

        # A valid sibling must not be uploaded before all multipart sizing succeeds.
        # The deliberately invalid URL prevents any network request in this test.
        assert {:error, :transport_exception} =
                 ReqClient.upload_files(
                   "room",
                   [%{body: "content", filename: "valid.txt"}, %{path: path, filename: "missing.txt"}],
                   attachment_failure_policy: @policy,
                   max_file_size: 1024,
                   url: "",
                   token: "test-token"
                 )
      end
    end

    @tag :tmp_dir
    test "omitted policy preserves path preparation exceptions", %{tmp_dir: tmp_dir} do
      assert_raise File.Error, fn ->
        ReqClient.upload_files("room", [%{path: Path.join(tmp_dir, "missing.txt")}],
          max_file_size: 1024,
          url: "",
          token: "test-token"
        )
      end
    end

    test "policy preparation retains ordinary validation errors" do
      for policy <- [:abort, :continue] do
        opts = [attachment_failure_policy: policy, max_file_size: nil]
        assert {:error, :missing_file_source} = ReqClient.upload_files("room", [%{}], opts)

        assert {:error, {:missing_configuration, :max_file_size}} =
                 ReqClient.upload_files("room", [%{body: "x", filename: "file.txt"}], opts)

        assert {:error, :upload_request_too_large} =
                 ReqClient.upload_files(
                   "room",
                   [%{body: "x", filename: String.duplicate("long", 1000)}],
                   Keyword.put(opts, :max_file_size, 1024)
                 )
      end
    end
  end
end
