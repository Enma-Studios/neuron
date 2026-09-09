defmodule Neuron.StructuredTest do
  use ExUnit.Case, async: true

  defmodule InvalidShapeModel do
    def complete(_messages, _opts) do
      {:ok, %{"choices" => [%{"message" => %{"content" => "{\"claims\":[123]}"}}]}}
    end
  end

  test "converts validator exceptions into repairable model-output errors" do
    validator = fn _json -> raise ArgumentError, "claims must be objects" end

    assert {:error, {:invalid_model_output, {:error, {:invalid_model_shape, message}}}} =
             Neuron.Structured.generate(
               "campaign_search.eex",
               %{
                 seller: "seller",
                 target: "target",
                 previous_queries: "[]",
                 leads: "[]",
                 failures: "[]"
               },
               validator,
               model_provider: InvalidShapeModel
             )

    assert message =~ "claims must be objects"
  end
end
