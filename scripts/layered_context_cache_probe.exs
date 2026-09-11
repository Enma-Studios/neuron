# Controlled probe of Z.ai prefix caching, isolated from search noise.
#
# Makes the same sequence of calls twice, once with the layered prefix and
# once with the pre-layer system message, varying only the task text, and
# records `prompt_tokens_details.cached_tokens` for each. A full campaign
# cannot answer this on its own: its prompt sizes vary by an order of
# magnitude between runs, so a cache effect is buried in search variance.

{:ok, _} = Application.ensure_all_started(:req)

tenant = %{
  "account" => "Enma Studios",
  "forbidden_claims" => [
    "do not claim an existing relationship, introduction or referral",
    "do not claim a named client without evidence in the campaign brief"
  ],
  "prior_decisions" => [
    "outreach is email first; other channels are drafts only",
    "no contact with branch offices of an existing customer"
  ],
  "tone" => "plain, specific, no superlatives"
}

campaign = %{
  "campaign" => "dogfood outbound, autumn 2026",
  "lead_target" => 1,
  "suppressions" => ["anyone already contacted under a previous Enma campaign"]
}

layered = [layered_context: true, tenant_overlay: tenant, campaign_overlay: campaign]
baseline = [layered_context: false]

tasks =
  for index <- 1..6 do
    "Return {\"n\": #{index}} and nothing else. Task #{index} of a sequence."
  end

probe = fn opts, label ->
  IO.puts("\n== #{label} ==")
  [system | _] = Neuron.Context.messages("x", opts)
  IO.puts("system message: #{byte_size(system.content)} bytes")

  results =
    for {task, index} <- Enum.with_index(tasks, 1) do
      messages = Neuron.Context.messages(task, opts)
      {:ok, response} = Neuron.Model.ZAI.complete(messages, [])
      usage = response["usage"] || %{}
      prompt = usage["prompt_tokens"] || 0
      cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
      IO.puts("  call #{index}: prompt #{prompt}, cached #{cached}")
      {prompt, cached}
    end

  prompt = Enum.sum(Enum.map(results, &elem(&1, 0)))
  cached = Enum.sum(Enum.map(results, &elem(&1, 1)))
  IO.puts("  total prompt #{prompt}, cached #{cached} (#{Float.round(cached / prompt * 100, 1)}%)")
  {label, prompt, cached, byte_size(system.content)}
end

results = [probe.(baseline, "baseline, pre-layer system message"), probe.(layered, "layered prefix")]

IO.puts("\n== summary ==")

for {label, prompt, cached, bytes} <- results do
  IO.puts("#{label}: #{bytes} byte prefix, #{prompt} prompt tokens, #{cached} cached (#{Float.round(cached / prompt * 100, 1)}%)")
end
