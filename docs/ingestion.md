# Shared ingestion

`Neuron.Ingestion.submit(%{url: url}, opts)` returns a durable run UUID. Inspect it with `Neuron.Ingestion.get(id)`. A caller can instead supply Markdown using `url`, `markdown`, `title`, and `fetched_at` (a UTC DateTime). These contracts are independent of campaigns; acquisition APIs and bots are not implemented.

Each document checkpoints fetching, evidence storage, AI normalization, reconciliation, and embedding indexing separately. Full cleaned Markdown reaches Dgraph before the model is called. Prompt excerpts are independently bounded by `prompt_characters` (24000). Embedding chunks use bounded GenStage processing (`embedding_concurrency`, default 2). SQL checkpoints and Oban jobs provide recovery; GenStage buffers do not.

Normalization accepts supported professional claims only, with exact source excerpts. The graph retains assertions and computes a current view by user precedence, authority, corroboration, and observation time. Campaigns share this knowledge. Run `mix neuron.dgraph.migrate` before ingestion; migration 000006 introduces claim and document predicates.

The configured embedding provider must work. Failed indexing leaves already recorded documents and claims intact and resumes through the run API. No synthetic production vectors are generated.
