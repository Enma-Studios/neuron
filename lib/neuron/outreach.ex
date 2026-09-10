defmodule Neuron.Outreach do
  @moduledoc "Validated channel-specific outreach drafts; never sends messages."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:channel, :string)
    field(:recipient, :string)
    field(:subject, :string)
    field(:body, :string)
  end

  def changeset(data, attrs) do
    changeset =
      data
      |> cast(attrs, [:channel, :recipient, :subject, :body])
      |> validate_required([:channel, :recipient, :body])
      |> validate_inclusion(:channel, ~w(email linkedin x social))

    channel = get_field(changeset, :channel)

    limit =
      Map.get(%{"email" => 2000, "linkedin" => 300, "x" => 500, "social" => 600}, channel, 600)

    changeset = validate_length(changeset, :body, max: limit)

    if channel == "email",
      do: validate_required(changeset, [:subject]),
      else:
        validate_change(changeset, :subject, fn :subject, _ ->
          [subject: "is only used for email"]
        end)
  end

  @doc """
  Attach the model's reason and, where there is somewhere to send it, its
  draft.

  A lead with no observed contact channel has no recipient, so there is no
  draft to validate and nothing the model returned as a channel is kept. An
  invented recipient must never reach a caller; the selection reason still
  must.
  """
  def confirm(draft, %{contact_channels: []} = lead) do
    case draft["reason"] do
      reason when is_binary(reason) and byte_size(reason) > 0 ->
        {:ok,
         Map.merge(lead, %{
           reason: reason,
           outreach: nil,
           email_subject: nil,
           email_body: nil
         })}

      _ ->
        {:error, {:invalid_channel_draft, :missing_reason}}
    end
  end

  def confirm(draft, lead) do
    [preferred | _] = lead.contact_channels

    with true <- draft["channel"] == preferred.kind,
         {:ok, output} <-
           Neuron.Contracts.validate(__MODULE__, %{
             channel: draft["channel"],
             recipient: preferred.value,
             subject: draft["subject"],
             body: draft["body"]
           }),
         reason when is_binary(reason) and byte_size(reason) > 0 <- draft["reason"] do
      {:ok,
       Map.merge(lead, %{
         reason: reason,
         outreach: Neuron.Contracts.plain(output),
         email_subject: if(output.channel == "email", do: output.subject),
         email_body: if(output.channel == "email", do: output.body)
       })}
    else
      error -> {:error, {:invalid_channel_draft, error}}
    end
  end
end
