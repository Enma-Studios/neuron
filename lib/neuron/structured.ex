defmodule Neuron.Structured do
  @moduledoc "EEx-backed JSON model calls with bounded contract repair."
  def generate(template, assigns, validator, opts \\ []) do
    with {:ok, prompt} <- Neuron.Prompt.render_file(template, assigns, opts) do
      # Layers 1 to 4 lead, so the head of every request is the same bytes
      # for the whole run. Layers 5 and 6 are the task prompt itself.
      complete(Neuron.Context.messages(prompt, opts), validator, opts, 2)
    end
  end

  defp complete(messages, validator, opts, remaining) do
    provider =
      Keyword.get(opts, :model_provider, Application.fetch_env!(:neuron, :model)[:provider])

    with {:ok, response} <- provider.complete(messages, opts) do
      content = get_in(response, ["choices", Access.at(0), "message", "content"])

      result =
        with true <- is_binary(content),
             {:ok, json} <-
               Jason.decode(
                 content
                 |> String.replace(~r/^```(?:json)?\s*|\s*```$/, "")
                 |> String.trim()
               ),
             do: validate(validator, json)

      case result do
        {:ok, value} ->
          {:ok, value}

        error when remaining > 0 ->
          Neuron.Telemetry.emit(
            [:model, :repair],
            Map.put(Neuron.Telemetry.trace_metadata(opts), :error, inspect(error))
          )

          complete(
            messages ++
              [
                %{role: "assistant", content: content || ""},
                %{
                  role: "user",
                  content:
                    "Repair the output using only supplied evidence. Validation error: #{inspect(error)}"
                }
              ],
            validator,
            opts,
            remaining - 1
          )

        error ->
          {:error, {:invalid_model_output, error}}
      end
    end
  end

  defp validate(validator, json) do
    validator.(json)
  rescue
    error in [ArgumentError, FunctionClauseError, KeyError, Protocol.UndefinedError] ->
      {:error, {:invalid_model_shape, Exception.message(error)}}
  end
end
