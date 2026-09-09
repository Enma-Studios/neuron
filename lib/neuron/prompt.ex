defmodule Neuron.Prompt do
  @moduledoc "Versioned EEx prompt rendering with traceable inputs."

  def render(template, assigns, opts \\ []) when is_binary(template) and is_map(assigns) do
    version = Keyword.get(opts, :version, "1")
    metadata = Neuron.Telemetry.trace_metadata(opts) |> Map.merge(%{template: template, template_version: version, assigns: Neuron.Telemetry.summarize(assigns)})

    Neuron.Telemetry.span([:prompt, :render], metadata, fn ->
      try do
        {:ok, EEx.eval_string(template, assigns: Map.to_list(assigns))}
      rescue
        error -> {:error, {:invalid_prompt, Exception.message(error)}}
      end
    end)
  end

  def render_file(name, assigns, opts \\ []) do
    path = Path.join(Application.get_env(:neuron, :prompts, [])[:path] || "priv/prompts", name)

    case File.read(path) do
      {:ok, template} -> render(template, assigns, Keyword.put_new(opts, :template, name))
      {:error, reason} -> {:error, {:prompt_not_found, name, reason}}
    end
  end
end
