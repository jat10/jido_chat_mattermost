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
      assert {:error, :missing_file_source} = ReqClient.upload_files("c1", [file], [])
    end

    assert {:error, :missing_file_source} = ReqClient.upload_files("c1", [], [])
  end

  test "upload and publication exceptions are always neutral without policy" do
    opts = [url: "", token: "test-token", max_upload_request_size: 2048]
    file = %{body: "bytes", filename: "file.txt"}
    assert {:error, :transport_exception} = ReqClient.upload_files("room", [file], opts)
    assert {:error, :transport_exception} = ReqClient.send_message("room", "Answer", opts)
    assert {:error, :transport_exception} = ReqClient.edit_message("room", "post", "Answer", opts)
  end

  test "exact encoded size is accepted and one byte less is rejected without hidden splitting" do
    files = [%{body: "bytes", filename: "file.txt"}, %{body: "two", filename: "second.txt"}]
    assert {:ok, prepared} = ReqClient.prepare_upload("room", files, max_upload_request_size: 10000)
    assert prepared.size_bytes == byte_size(prepared.body)
    assert length(prepared.files) == 2
    assert prepared.body =~ "bytes"
    assert prepared.body =~ "second.txt"
    assert prepared.content_type =~ "multipart/form-data; boundary="
    assert {:ok, exact} = ReqClient.prepare_upload("room", files, max_upload_request_size: prepared.size_bytes)
    assert exact.size_bytes == prepared.size_bytes

    assert {:error, :upload_request_too_large} =
             ReqClient.prepare_upload("room", files, max_upload_request_size: prepared.size_bytes - 1)

    assert {:error, :upload_request_too_large} =
             ReqClient.upload_prepared(prepared, max_upload_request_size: prepared.size_bytes - 1)
  end

  test "header-heavy and too-large singleton candidates are rejected as a whole" do
    for files <- [
          [%{body: "x", filename: String.duplicate("long", 1000)}],
          [%{body: String.duplicate("x", 2048), filename: "large.txt"}],
          [%{body: "x", filename: "small.txt"}, %{body: "x", filename: String.duplicate("long", 1000)}]
        ] do
      assert {:error, :upload_request_too_large} =
               ReqClient.prepare_upload("room", files, max_upload_request_size: 1024)
    end
  end

  test "request limits are explicit and independent of per-file limits" do
    file = %{body: "x", filename: "file.txt"}

    for {limit, reason} <- [
          {nil, :missing_configuration},
          {0, :invalid_configuration},
          {-1, :invalid_configuration},
          {"10", :invalid_configuration}
        ] do
      assert {:error, {^reason, :max_upload_request_size}} =
               ReqClient.prepare_upload("room", [file], max_upload_request_size: limit, max_file_size: 999_999)
    end

    assert {:ok, _} = ReqClient.prepare_upload("room", [file], max_upload_request_size: 2048, max_file_size: nil)
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
             ReqClient.prepare_upload("room", [%{path: path}], max_upload_request_size: 2048)

    assert {:error, :file_unavailable} = ReqClient.upload_files("room", [%{path: path}], max_upload_request_size: 2048)
    File.write!(path, "bytes")

    assert {:error, :file_not_materialized} =
             ReqClient.prepare_upload("room", [%{path: path}], max_upload_request_size: 2048)

    assert {:error, :transport_exception} =
             ReqClient.upload_files("room", [%{path: path}],
               max_upload_request_size: 2048,
               url: "",
               token: "test-token"
             )
  end
end
