defmodule Neuron.ContactPolicy do
  @moduledoc "Evidence rules and soft source preferences for contact selection."

  @preferred_hosts ~w(
    linkedin.com www.linkedin.com github.com www.github.com gitlab.com
    x.com twitter.com www.twitter.com facebook.com www.facebook.com
    instagram.com www.instagram.com youtube.com www.youtube.com
    crunchbase.com www.crunchbase.com wellfound.com angel.co clutch.co g2.com
    producthunt.com medium.com substack.com dev.to reddit.com kaggle.com
    huggingface.co npmjs.com pypi.org about.me
  )
  @excluded_markers ["distinct company", "distinct organization", "branch office", "franchise"]
  @personal_hosts ~w(gmail.com yahoo.com outlook.com hotmail.com proton.me protonmail.com icloud.com)

  def eligible?(person, target_domain, opts \\ []) when is_map(person) do
    name = text(person["name"] || person[:name])

    body =
      Enum.join([person["title"] || person[:title], person["bio"] || person[:bio]], " ") |> text()

    profile_url = person["profile_url"] || person[:profile_url] || ""
    evidence_urls = List.wrap(person["evidence_urls"] || person[:evidence_urls])

    name != "" and
      not Enum.any?(@excluded_markers, &String.contains?(body, &1)) and
      plausible_source?(target_domain, profile_url, evidence_urls) and
      not only_personal_sources?(profile_url, evidence_urls) and
      not location_conflict?(person, opts)
  end

  def suggestions(person, target_domain, opts \\ []) do
    profile_url = person["profile_url"] || person[:profile_url] || ""
    host = URI.parse(profile_url).host || ""
    location = text(person["location"] || person[:location])
    preferred = Keyword.get(opts, :preferred_geographies, [])

    []
    |> maybe_add(
      host not in @preferred_hosts and host != target_domain,
      "source is unranked; corroborate with a primary or trusted profile"
    )
    |> maybe_add(
      preferred != [] and location != "" and
        not Enum.any?(preferred, &String.contains?(location, text(&1))),
      "location is outside the preferred geography"
    )
  end

  defp plausible_source?(_target_domain, profile_url, evidence_urls) do
    urls = [profile_url | evidence_urls]
    Enum.any?(urls, &(is_binary(&1) and String.starts_with?(&1, "http")))
  end

  defp only_personal_sources?(profile_url, evidence_urls) do
    urls = [profile_url | evidence_urls] |> Enum.filter(&is_binary/1)
    urls != [] and Enum.all?(urls, fn url -> (URI.parse(url).host || "") in @personal_hosts end)
  end

  defp location_conflict?(person, opts) do
    preferred = Keyword.get(opts, :preferred_geographies, [])
    location = text(person["location"] || person[:location])

    preferred != [] and location != "" and
      not Enum.any?(preferred, &String.contains?(location, text(&1)))
  end

  defp maybe_add(list, true, value), do: [value | list]
  defp maybe_add(list, false, _value), do: list
  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.downcase()
end
