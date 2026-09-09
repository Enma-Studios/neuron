defmodule Neuron.Schemas.SocialAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:platform, :string)
    field(:handle, :string)
    field(:profile_url, :string)
  end

  def changeset(data, attrs),
    do:
      data
      |> cast(attrs, [:platform, :handle, :profile_url])
      |> validate_required([:platform, :profile_url])
end

defmodule Neuron.Schemas.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:title, :string)
    field(:bio, :string)
    field(:location, :string)
    field(:profile_url, :string)
    embeds_many(:social_accounts, Neuron.Schemas.SocialAccount)
  end

  def changeset(data, attrs),
    do:
      data
      |> cast(attrs, [:name, :title, :bio, :location, :profile_url])
      |> cast_embed(:social_accounts, with: &Neuron.Schemas.SocialAccount.changeset/2)
      |> validate_required([:name])
end

defmodule Neuron.Schemas.Lead do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:person_name, :string)
    field(:title, :string)
    field(:email, :string)
    field(:fit_score, :float)
    field(:reason, :string)
    field(:email_subject, :string)
    field(:email_body, :string)
    field(:evidence_urls, {:array, :string}, default: [])
  end

  def changeset(data, attrs),
    do:
      data
      |> cast(attrs, [
        :person_name,
        :title,
        :email,
        :fit_score,
        :reason,
        :email_subject,
        :email_body,
        :evidence_urls
      ])
      |> validate_required([:person_name, :reason])
      |> validate_number(:fit_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
      |> validate_change(:evidence_urls, fn :evidence_urls, urls ->
        if Enum.all?(urls, &is_binary/1), do: [], else: [is_invalid: "must contain URLs"]
      end)
end

defmodule Neuron.Schemas.CampaignResult do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:status, :string)
    field(:campaign_run_id, :string)
    field(:target_count, :integer)
    field(:campaign, :map, default: %{})
    field(:failures, {:array, :map}, default: [])
    field(:campaign_outbox_id, :string)
    embeds_many(:leads, Neuron.Schemas.Lead)
  end

  def changeset(data, attrs),
    do:
      data
      |> cast(attrs, [
        :status,
        :campaign_run_id,
        :target_count,
        :campaign,
        :failures,
        :campaign_outbox_id
      ])
      |> cast_embed(:leads, with: &Neuron.Schemas.Lead.changeset/2)
      |> validate_required([:status, :campaign_run_id, :target_count])
      |> validate_inclusion(:status, ["target_met", "failed"])
      |> validate_number(:target_count, greater_than_or_equal_to: 1)
end

defmodule Neuron.Schemas.Research do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:domain, :string)
    field(:organization, :map, default: %{})
    field(:people, {:array, :map}, default: [])
    field(:posts, {:array, :map}, default: [])
    field(:leads, {:array, :map}, default: [])
    field(:assertions, {:array, :map}, default: [])
    field(:target_profile, :map, default: %{})
  end

  def changeset(data, attrs),
    do:
      data
      |> cast(attrs, [
        :domain,
        :organization,
        :people,
        :posts,
        :leads,
        :assertions,
        :target_profile
      ])
      |> validate_required([:domain])
      |> validate_format(:domain, ~r/^[^\s.]+(?:\.[^\s.]+)+$/)
      |> validate_change(:people, &validate_people/2)
      |> validate_change(:leads, &validate_leads/2)

  defp validate_people(:people, people) do
    if Enum.all?(people, &valid_changeset?(Neuron.Schemas.Person, &1)),
      do: [],
      else: [invalid: "contains malformed person"]
  end

  defp validate_leads(:leads, leads) do
    if Enum.all?(leads, &valid_changeset?(Neuron.Schemas.Lead, &1)),
      do: [],
      else: [invalid: "contains malformed lead"]
  end

  defp valid_changeset?(module, attrs), do: module.changeset(struct(module), attrs).valid?
end

defmodule Neuron.Schemas do
  @moduledoc "Ecto embedded contracts for model output and persisted lead shapes."

  def validate_research(attrs) when is_map(attrs) do
    changeset = Neuron.Schemas.Research.changeset(%Neuron.Schemas.Research{}, attrs)

    if changeset.valid?,
      do: {:ok, Ecto.Changeset.apply_changes(changeset)},
      else: {:error, Ecto.Changeset.traverse_errors(changeset, &format_error/1)}
  end

  def sanitize_research(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.update("people", [], fn people -> Enum.map(List.wrap(people), &sanitize_person/1) end)
      |> Map.update("leads", [], fn leads -> Enum.map(List.wrap(leads), &sanitize_lead/1) end)
      |> Map.put_new("domain", "unknown.invalid")

    valid_people = Enum.filter(attrs["people"], &valid?(Neuron.Schemas.Person, &1))
    valid_leads = Enum.filter(attrs["leads"], &valid?(Neuron.Schemas.Lead, &1))

    attrs
    |> Map.put("people", valid_people)
    |> Map.put("leads", valid_leads)
  end

  @doc "Validate the stable public shape returned by campaign orchestration."
  def validate_campaign_result(attrs) when is_map(attrs) do
    status = Map.get(attrs, :status, Map.get(attrs, "status"))

    attrs =
      if Map.has_key?(attrs, "status"),
        do: Map.put(attrs, "status", to_string(status)),
        else: Map.put(attrs, :status, to_string(status))

    changeset = Neuron.Schemas.CampaignResult.changeset(%Neuron.Schemas.CampaignResult{}, attrs)

    if changeset.valid?,
      do: {:ok, Ecto.Changeset.apply_changes(changeset)},
      else: {:error, Ecto.Changeset.traverse_errors(changeset, &format_error/1)}
  end

  defp sanitize_person(person) when is_map(person) do
    Map.update(person, "social_accounts", [], fn accounts ->
      Enum.map(List.wrap(accounts), fn
        account when is_binary(account) ->
          %{"platform" => platform(account), "profile_url" => account, "handle" => ""}

        account ->
          account
      end)
    end)
  end

  defp sanitize_person(person), do: %{"name" => to_string(person)}

  defp sanitize_lead(lead) when is_map(lead), do: lead

  defp sanitize_lead(lead),
    do: %{"person_name" => to_string(lead), "reason" => "Model supplied a named contact"}

  defp valid?(module, attrs), do: module.changeset(struct(module), attrs).valid?

  defp platform(url) do
    case URI.parse(url).host do
      host when is_binary(host) ->
        host |> String.replace_prefix("www.", "") |> String.split(".") |> List.first()

      _ ->
        "web"
    end
  end

  defp format_error({message, opts}),
    do:
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
end
