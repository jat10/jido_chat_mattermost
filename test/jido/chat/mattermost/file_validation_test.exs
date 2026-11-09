defmodule Jido.Chat.Mattermost.FileValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Adapter

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  test "validates lazy metadata without touching content, paths or transport" do
    files = [
      %{name: "empty.txt", size: 0, path: "/does/not/exist"},
      %{"filename" => "limit.txt", "metadata" => %{"size" => 10}},
      %{name: "nested.txt", metadata: %{size: 1}, content: nil}
    ]

    assert :ok = Adapter.validate_files(files, max_file_size: 10, transport: MustNotBeCalled)
  end

  test "returns the oversized file to the caller before any upload" do
    files = [%{name: "ok", size: 10}, %{name: "large", size: 11}]

    assert {:error, {:file_too_large, %{filename: "large", size: 11, limit: 10}}} =
             Adapter.validate_files(files, max_file_size: 10)
  end

  test "rejects missing or invalid sizes and malformed batches" do
    for size <- [nil, -1, "10", 1.5] do
      assert {:error, {:invalid_file_size, %{filename: "file"}}} =
               Adapter.validate_files([%{name: "file", size: size}], max_file_size: 10)
    end

    assert {:error, :invalid_file_metadata} = Adapter.validate_files([nil], max_file_size: 10)
    assert {:error, :invalid_files} = Adapter.validate_files(nil, max_file_size: 10)
  end

  test "requires valid configuration only for nonempty batches" do
    assert :ok = Adapter.validate_files([], max_file_size: nil)

    assert {:error, {:missing_configuration, :max_file_size}} =
             Adapter.validate_files([%{size: 1}], max_file_size: nil)

    for limit <- [0, -1, "10"] do
      assert {:error, {:invalid_configuration, :max_file_size}} =
               Adapter.validate_files([%{size: 1}], max_file_size: limit)
    end
  end
end
