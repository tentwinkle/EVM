defmodule EVM.Operation.Metadata do
  @moduledoc """
  A simple struct to store metadata about all VM instructions.
  """

  defstruct id: nil,
            sym: nil,
            fun: nil,
            args: [],
            input_count: nil,
            output_count: nil,
            description: nil,
            group: :other,
            machine_code_offset: 0

  @type t :: %__MODULE__{
          :id => integer(),
          :sym => atom(),
          :fun => atom(),
          :args => [],
          # Denoted as δin the Yellow Paper
          :input_count => integer(),
          # Denoted as αin the Yellow Paper
          :output_count => integer(),
          :description => String.t(),
          :group => atom(),
          :machine_code_offset => integer() | nil
        }
end
