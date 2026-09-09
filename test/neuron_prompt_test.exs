defmodule Neuron.PromptTest do
  use ExUnit.Case, async: true

  test "renders EEx assigns" do
    assert {:ok, "Hello Ada"} = Neuron.Prompt.render("Hello <%= @name %>", %{name: "Ada"})
  end

  test "returns a structured error for invalid templates" do
    assert {:error, {:invalid_prompt, _}} = Neuron.Prompt.render("<%= @missing", %{})
  end

  test "ships the research output confirmation prompt" do
    assert {:ok, prompt} =
             Neuron.Prompt.render_file("confirm_output.eex", %{errors: "{}", output: "{}"})

    assert prompt =~ "Ecto output contract"
  end
end
