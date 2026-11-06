defmodule Jido.Chat.Mattermost.SendOptions do
  @moduledoc "Options for sending a Mattermost post."

  defstruct max_file_size: nil, thread_id: nil, token: nil, transport: nil, url: nil

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          max_file_size: pos_integer() | nil,
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Build a `SendOptions` from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      thread_id: opts[:thread_id] || opts[:external_thread_id] || opts[:reply_to_id],
      max_file_size: Keyword.get(opts, :max_file_size, Application.get_env(:jido_chat_mattermost, :max_file_size)),
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extract the keyword opts the transport layer needs."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:max_file_size, o.max_file_size)
    |> maybe_put(:thread_id, o.thread_id)
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
