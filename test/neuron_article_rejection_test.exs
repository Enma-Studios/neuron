defmodule Neuron.ArticleRejectionTest do
  use ExUnit.Case, async: true

  alias Neuron.Search.Harvest

  # Harvested and ingested tonight by runs 92450aed and b771bc4c. None of them
  # names a buyer's decision makers.
  @articles [
    "https://blog.iomergent.com/should-first-security-hire-be-ciso-or-engineer",
    "https://ravenmoor.example/ciso/first-security-hire-is-not-an-engineer/",
    "https://medium.com/people-ai-engineering/how-to-startup-security-when-you-dont-have-a-security-department-yet-part-1-e8760600939d",
    "https://unsecure.substack.com/p/when-is-it-time-for-your-first-security",
    "https://gracker.ai/llms.txt",
    "https://thefinancialtechnologyreport.com/the-top-25-financial-technology-ctos-of-2021/",
    "https://thefinancialtechnologyreport.com/top-financial-technology-ceos-of-2025/",
    "https://franklyspeaking.substack.com/p/what-does-a-first-security-hire-look",
    "https://goauthentik.io/blog/2024-06-11-first-90-days/",
    "https://onpay.com/insights/payroll-security/",
    "https://www.adp.com/resources/articles-and-insights/articles/s/saas-payroll.aspx",
    "https://tobyhale.example/selling-my-bootstrapped-saas-business/",
    "https://yarrowkhan.example/post/10-years-of-success-and-failures-as-a-bootstrapped-saas-founder",
    "https://onpay.com/about-us/author/jordan-vale/",
    "https://www.linkedin.com/pulse/como-crear-un-plan-director-seguridad-de-la-y-forma-e-varda"
  ]

  # Company pages from the same runs: team, leadership, about, contact,
  # product and home pages.
  @company_pages [
    "https://www.ciso.inc/company/leadership/",
    "https://atlastravel.com/company/leadership",
    "https://careers.booking.com/teams/leadership/",
    "https://www.bookingholdings.com/about/leadership/",
    "https://www.ascentregtech.com/leadership/",
    "https://www.fintech-galaxy.com/about-us/team",
    "https://securityscorecard.com/company/leadership/",
    "https://ravenmoor.example/contact/",
    "https://gusto.com/product/payroll/secure",
    "https://www.entrust.com/use-case/kyc",
    "https://blinq.me/security/responsible-disclosure-program",
    "https://www.paychex.com/",
    "https://inovapayroll.com/"
  ]

  test "every article harvested tonight is rejected by its URL alone" do
    for url <- @articles do
      assert Harvest.article_reason(url), "#{url} was not rejected"
    end
  end

  test "company pages from the same runs are kept" do
    for url <- @company_pages do
      assert Harvest.article_reason(url) == nil,
             "#{url} was rejected as #{inspect(Harvest.article_reason(url))}"
    end
  end

  defmodule Engine do
    @behaviour Neuron.Search.Engine

    def kind, do: :web
    def keywords(query), do: query

    def search_url(keywords),
      do: "https://api.keyed.example/search?q=#{URI.encode_www_form(keywords)}"

    def parse(_body), do: []
    def blocked?(_body), do: false
    def gated?(_body), do: false
    def available?, do: true

    def transcript(task, _opts) do
      links = [
        %{
          href: "https://unsecure.substack.com/p/when-is-it-time-for-your-first-security",
          label: "Post"
        },
        %{href: "https://acme.example/about/leadership", label: "Leadership"}
      ]

      {:ok,
       %{
         url: task.url,
         title: "Results",
         markdown: Enum.map_join(links, "\n", &"- [#{&1.label}](#{&1.href})"),
         text: "Results",
         document: "",
         links: links,
         engine: __MODULE__,
         query: task.query
       }}
    end
  end

  # The model selects both, as it did tonight.
  defmodule Model do
    def complete(_messages, _opts) do
      content =
        Jason.encode!(%{
          "results" => [
            %{
              "title" => "Post",
              "url" => "https://unsecure.substack.com/p/when-is-it-time-for-your-first-security",
              "reason" => "discusses security hires"
            },
            %{
              "title" => "Leadership",
              "url" => "https://acme.example/about/leadership",
              "reason" => "team"
            }
          ]
        })

      {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
    end
  end

  test "the search stage ingests only the company page, and records the rejected article" do
    data = %{
      campaign: %{seller_profile: %{domain: "nyx-labs.org"}},
      pending_searches: [%{engine: Engine, query: "acme leadership"}],
      searches: [],
      urls: [],
      failures: []
    }

    assert {:ok, data} =
             Neuron.CampaignPipeline.stage(:search, data,
               engines: [Engine],
               model_provider: Model
             )

    assert Enum.map(data.pending_children, & &1.source.url) == [
             "https://acme.example/about/leadership"
           ]

    assert [
             %{
               url: "https://unsecure.substack.com/p/when-is-it-time-for-your-first-security",
               reason: reason
             }
           ] =
             data.rejected_sources

    assert is_atom(reason)
  end
end
