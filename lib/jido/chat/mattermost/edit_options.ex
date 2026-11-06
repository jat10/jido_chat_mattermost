defmodule Jido.Chat.Mattermost.EditOptions do
  @moduledoc "Options for editing a Mattermost post."

  defstruct max_file_size: nil, files: [], previous_metadata: %{}, token: nil, transport: nil, url: nil

  @type t :: %__MODULE__{
          files: [Jido.Chat.FileUpload.t()],
          previous_metadata: map(),
          max_file_size: pos_integer() | nil,
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Builds edit options from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      files: Keyword.get(opts, :files, []),
      previous_metadata: Keyword.get(opts, :previous_metadata, %{}),
      max_file_size: Keyword.get(opts, :max_file_size, Application.get_env(:jido_chat_mattermost, :max_file_size)),
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extracts transport options for edit requests."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:max_file_size, o.max_file_size)
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
