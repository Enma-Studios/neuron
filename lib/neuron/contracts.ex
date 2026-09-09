defmodule Neuron.Contracts.Seller do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:domain, :string)
    field(:name, :string)
    field(:field, :string)
    field(:offer, :string)
    field(:geography, {:array, :string}, default: [])
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:domain, :name, :field, :offer, :geography])
    |> validate_required([:domain, :offer])
  end
end

defmodule Neuron.Contracts.Target do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:markets, {:array, :string}, default: [])
    field(:roles, {:array, :string}, default: [])
    field(:geography, {:array, :string}, default: [])
    field(:exclusions, {:array, :string}, default: [])
  end

  def changeset(value, attrs) do
    value |> cast(attrs, [:markets, :roles, :geography, :exclusions])
  end
end

defmodule Neuron.Contracts.Document do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:url, :string)
    field(:title, :string, default: "")
    field(:markdown, :string)
    field(:provider, :string)
    field(:fetched_at, :utc_datetime_usec)
    field(:published_at, :utc_datetime_usec)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:url, :title, :markdown, :provider, :fetched_at, :published_at])
    |> validate_required([:url, :markdown, :fetched_at])
    |> validate_format(:url, ~r/^https?:\/\/[^\s\/]+/)
  end
end

defmodule Neuron.Contracts.Claim do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:entity_type, :string)
    field(:identity, :string)
    field(:predicate, :string)
    field(:value, :string)
    field(:excerpt, :string)
    field(:source_url, :string)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:entity_type, :identity, :predicate, :value, :excerpt, :source_url])
    |> validate_required([:entity_type, :identity, :predicate, :value, :excerpt, :source_url])
    |> validate_inclusion(:entity_type, ["Organization", "Person", "Post", "SocialAccount"])
    |> validate_inclusion(:predicate, [
      "name",
      "description",
      "industry",
      "title",
      "email",
      "employer",
      "location",
      "profile_url",
      "body",
      "organization",
      "owner",
      "requirements",
      "capabilities",
      "clients"
    ])
  end
end

defmodule Neuron.Contracts do
  @moduledoc "Validated boundaries shared by campaigns and source-independent ingestion."
  def validate(module, attrs) when is_map(attrs) do
    module.changeset(struct(module), attrs) |> Ecto.Changeset.apply_action(:validate)
  end

  def validate(_module, attrs), do: {:error, {:invalid_attributes, attrs}}

  def plain(%_{} = value), do: value |> Map.from_struct() |> Map.drop([:__meta__]) |> plain()
  def plain(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, plain(v)} end)
  def plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  def plain(value), do: value
end
