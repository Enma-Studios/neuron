defmodule Mix.Tasks.Neuron.Repl do
  use Mix.Task
  @shortdoc "Start the Owl campaign console"
  def run([]) do
    Mix.Task.run("app.start")
    Neuron.REPL.start()
  end
end
