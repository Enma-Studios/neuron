# Architecture

Neuron is an OTP application containing a repository (unless host managed), Oban (unless host managed), the Dlex connection owner, and a dynamic supervisor for per-stage GenStage trees.

## Durable execution

`Neuron.FSM` provides a small definition DSL. A machine has a definition module, state, monotonically increasing version, and serialized data. `send/4` resolves an event against the current state, applies a named guard, conditionally updates the row using its previous version, appends a SQL event, and inserts the next Oban job in the same transaction. Competing updates cannot both commit the same version. Transaction failures propagate; Oban retries job failures.

The job records the machine ID and transition version. Workers check the version before execution and again when advancing. A stale job returns successfully without advancing the machine. State transitions emit telemetry after their transaction succeeds.

This is an application-specific durable FSM, not an implementation of every `gen_statem` feature. There are no process mailboxes, state timeouts, event postponement, or synchronous actor calls. Delayed workers use a transition's `after:` option. Version-bound delayed events use `schedule_event/3`.

## Queues and stages

`orchestrators` executes ordinary coordinator planning/execution and campaign collection. `agents` executes pipeline planning, stages, and timers. Separating those queues allows a campaign job to await a research child without blocking its planner. Both queues must be configured by a host.

Research runs six stages: discovery, source browsing, extraction, reconciliation/enrichment, drafting/validation, and graph persistence. Each successful stage replaces its saved checkpoint and queues the next stage. Source workers run under a temporary supervised GenStage tree, with demand of one per mapper and configurable concurrency. Results may arrive in any order. A worker crash propagates to the Oban stage; cleanup terminates the tree. Failed individual pages are traced and excluded, while failure to search or obtain any pages fails the stage.

Oban retries a failed stage up to five attempts using its backoff. An ordinary exception on the last attempt marks the FSM failed and is re-raised for Oban's failure record. `resume_run/1` queues the saved pipeline stage. Ordinary coordinator runs restart planning when resumed.

## Recovery and side effects

Execution is at least once. A crash after an external request but before its checkpoint can repeat the request. Version checks prevent stale output from changing the FSM; they cannot undo a request already sent. Dgraph writes use stable external identities with an `@upsert` index, resolving all blank-node references in a single mutation. New SQL code does not migrate or deduplicate pre-existing Dgraph nodes that lack those identities.

Oban's configured Lifeline handles orphaned executing jobs; configure its rescue age above your maximum legitimate job duration. A process killed during its final attempt can be discarded by Oban before application failure handling runs. `get_run/1` and `resume_run/1` reconcile that discarded job into a failed run using its version before returning or retrying. SQLite is for local iteration; configure Postgres for distributed operation.

## Data ownership

Dgraph is the canonical domain store. SQL retains operational copies of intermediate inputs and outputs necessary for replay, plus raw prompts, model responses, decisions, and transition events. It is not a second domain query database. Serialized execution data must not contain PIDs, ports, references, or functions. Keep callback module names available across deployments and drain incompatible jobs before changing payload shapes.

The graph describes organizations, employment, people, social accounts, posts/authors, sources/snapshots, requirements, geographies, client profiles, capabilities, assertions, campaigns, and leads. Full-text predicates and vector indexes are defined by versioned Dgraph migrations. Reconciliation currently combines evidence through model prompts and stable writes; it does not automatically retract old relationships absent from a later extraction.

## Embedding

A host supplies an Ecto repo and an Oban instance configured against that same repo. No Phoenix modules or dependencies are required. HTTP controllers can call `start_run/3`, store the returned ID, and poll `get_run/1` or subscribe to telemetry in their own application.

## Campaign discovery and shared ingestion

Seller intake never identifies the seller's own employees as prospects. A campaign pipeline retrieves shared knowledge, plans platform-tailored searches (LinkedIn, X, and Reddit are covered natively every round even when the planner omits them), and runs them as one fleet wave: a handful of browser sessions each multiplex concurrent pages, one sub-agent per page returns a transcript, and the model harvests prospect URLs from those transcripts under an exact-URL contract. Login-gated pages count as engine failures, not results. The pipeline checkpoints child UUIDs and submits one durable ingestion job per source. A waiting parent snoozes through Oban rather than holding a worker while children run. GenStage bounds concurrency inside search and embedding stages.

Each source records full Markdown before normalization. Claims retain excerpt, source, authority and observation time; reconciliation preserves alternatives and selects current values. Entities have searchable text and local multilingual embeddings. Selection combines semantic and lexical relevance with role, geography, evidence quality and freshness, after enforcing professional-contact qualification and campaign repeat suppression.

Graph writes and SQL checkpoints are separate transactions and must be replay-safe. Selection reservations live in SQL for atomic campaign/person exclusion; delivered domain results and evidence live in Dgraph. Failed campaigns retain reservations until resumed or cancelled. Prompt/model payloads are telemetry events, not a custom transcript file.
