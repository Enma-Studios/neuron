defmodule Neuron.REPL do
  @moduledoc "Interactive campaign console using the embeddable Neuron API. No evaluator or mail sender."
  def start do
    Owl.IO.puts(Owl.Data.tag("Neuron campaign console", :cyan))
    Owl.IO.puts("Commands: campaign [URL], show ID, events ID, cancel ID, resume ID, quit")
    loop()
  end

  defp loop do
    case Owl.IO.input(label: "neuron", optional: true) do
      nil ->
        :ok

      "quit" ->
        :ok

      command ->
        command |> String.split(" ", parts: 2, trim: true) |> dispatch() |> display()
        loop()
    end
  end

  @doc "Execute a console command without starting the input loop."
  def dispatch(["campaign"]), do: campaign(%{})
  def dispatch(["campaign", url]), do: campaign(%{url: url})
  def dispatch(["show", id]), do: Neuron.get_run(id)
  def dispatch(["events", id]), do: Neuron.events(id)
  def dispatch(["cancel", id]), do: Neuron.cancel_run(id)
  def dispatch(["resume", id]), do: Neuron.resume_run(id)
  def dispatch(_), do: {:error, :unknown_command}

  defp campaign(input) do
    case Neuron.Campaign.intake(input) do
      {:ok, campaign} ->
        launch(campaign)

      {:needs_input, %{questions: questions, partial: partial}} ->
        answers =
          Enum.reduce(Enum.take(questions, 8), partial, fn question, acc ->
            value = Owl.IO.input(label: question.prompt, optional: !question.required)
            Map.put(acc, question.key, value)
          end)

        case Neuron.Campaign.intake(Map.drop(answers, [:url, :website])) do
          {:ok, campaign} -> launch(campaign)
          other -> other
        end

      {:approval_required, %{campaigns: campaigns} = details} ->
        display(details)
        choice = Owl.IO.select(["Approve all", "Choose one", "Different campaign", "Cancel"])

        case choice do
          "Approve all" ->
            approve_and_launch(details, :all)

          "Choose one" ->
            chosen = Owl.IO.select(Enum.with_index(campaigns), render_as: &inspect(elem(&1, 0)))
            approve_and_launch(details, elem(chosen, 1))

          "Different campaign" ->
            campaign(%{action: :different_campaign})

          "Cancel" ->
            {:ok, :cancelled}
        end

      error ->
        error
    end
  end

  defp approve_and_launch(details, selection) do
    with {:ok, campaigns} <- Neuron.Campaign.approve(details, selection),
         do: Enum.map(campaigns, &launch/1)
  end

  defp launch(campaign),
    do: Neuron.start_run(Neuron.Coordinator.Campaign, %{approved_campaign: campaign})

  defp display(value), do: Owl.IO.puts(inspect(value, pretty: true, limit: :infinity))
end
