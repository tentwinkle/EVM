defmodule EVM.Gas do
  @moduledoc """
  Functions for interacting wth gas and costs of opscodes.
  """

  alias EVM.MachineState
  alias EVM.ExecEnv
  alias MerklePatriciaTree.Trie

  @type t :: EVM.val
  @type gas_price :: EVM.Wei.t

  @g_zero 0  # Nothing paid for operations of the set Wzero.
  @g_base 2  # Amount of gas to pay for operations of the set Wbase.
  @g_verylow 3  # Amount of gas to pay for operations of the set Wverylow.
  @g_low 5  # Amount of gas to pay for operations of the set Wlow.
  @g_mid 8  # Amount of gas to pay for operations of the set Wmid.
  @g_high 10  # Amount of gas to pay for operations of the set Whigh.
  @g_extcode 700  # Amount of gas to pay for operations of the set Wextcode.
  @g_balance 400  # Amount of gas to pay for a BALANCE operation.
  @g_sload 200  # Paid for a SLOAD operation.
  @g_jumpdest 1  # Paid for a JUMPDEST operation.
  @g_sset 20000  # Paid for an SSTORE operation when the storage value is set to non-zero from zero.
  @g_sreset 5000  # Paid for an SSTORE operation when the storage value’s zeroness remains unchanged or is set to zero.
  @g_sclear 15000  # Refund given (added into refund counter) when the storage value is set to zero from non-zero.
  @g_suicide 24000  # Refund given (added into refund counter) for suiciding an account.
  @g_suicide 5000  # Amount of gas to pay for a SUICIDE operation.
  @g_create 32000  # Paid for a CREATE operation.
  @g_codedeposit 200  # Paid per byte for a CREATE operation to succeed in placing code into state.
  @g_call 700  # Paid for a CALL operation.
  @g_callvalue 9000  # Paid for a non-zero value transfer as part of the CALL operation.
  @g_callstipend 2300  # A stipend for the called contract subtracted from Gcallvalue for a non-zero value transfer.
  @g_newaccount 25000  # Paid for a CALL or SUICIDE operation which creates an account.
  @g_exp 10  # Partial payment for an EXP operation.
  @g_expbyte 10  # Partial payment when multiplied by dlog256(exponent)e for the EXP operation.
  @g_memory 3  # Paid for every additional word when expanding memory.
  @g_txcreate 32000  # Paid by all contract-creating transactions after the Homestead transition.
  @g_txdatazero 4  # Paid for every zero byte of data or code for a transaction.
  @g_txdatanonzero 68  # Paid for every non-zero byte of data or code for a transaction.
  @g_transaction 21000  # Paid for every transaction.
  @g_log 375  # Partial payment for a LOG operation.
  @g_logdata 8  # Paid for each byte in a LOG operation’s data.
  @g_logtopic 375  # Paid for each topic of a LOG operation.
  @g_sha3 30  # Paid for each SHA3 operation.
  @g_sha3word 6  # Paid for each word (rounded up) for input data to a SHA3 operation.
  @g_copy 3  # Partial payment for *COPY operations, multiplied by words copied, rounded up.
  @g_blockhash 20  # Payment for BLOCKHASH operation

  @w_zero_instr [:stop, :return]
  @w_base_instr [:address, :origin, :caller, :callvalue, :calldatasize, :codesize, :gasprice, :coinbase, :timestamp, :number, :difficulty, :gaslimit, :pop, :pc, :msize, :gas]
  @w_very_low_instr [
    :add, :sub, :not, :lt, :gt, :slt, :sgt, :eq, :iszero, :and, :or, :xor, :byte, :calldataload, :mload, :mstore, :mstore8,
    :push0, :push1, :push2, :push3, :push4, :push5, :push6, :push7, :push8, :push9, :push10, :push11, :push12, :push13, :push14, :push15, :push16,
    :dup0, :dup1, :dup2, :dup3, :dup4, :dup5, :dup6, :dup7, :dup8, :dup9, :dup10, :dup11, :dup12, :dup13, :dup14, :dup15, :dup16,
    :swap0, :swap1, :swap2, :swap3, :swap4, :swap5, :swap6, :swap7, :swap8, :swap9, :swap10, :swap11, :swap12, :swap13, :swap14, :swap15, :swap16,
  ]
  @w_low_instr [:mul, :div, :sdiv, :mod, :smod, :signextend]
  @w_mid_instr [:addmod, :mulmod, :jump]
  @w_high_instr [:jumpi]
  @w_extcode_instr [:extcodesize]


  @doc """
  Returns the cost to execute the given a cycle of the VM. This is defined
  in Appenix H of the Yellow Paper, Eq.(220) and is denoted `C`.

  ## Examples

      # TODO: Figure out how to hand in state
      iex> EVM.Gas.cost(%{}, %EVM.MachineState{}, %EVM.ExecEnv{})
      0
  """
  @spec cost(EVM.state, MachineState.t, ExecEnv.t) :: t | nil
  def cost(state, machine_state, exec_env) do
    instruction = EVM.MachineCode.current_instruction(machine_state, exec_env) |> EVM.Instruction.decode()
    next_active_words = EVM.Instruction.Memory.active_words_after(instruction, state, machine_state, exec_env)

    case instr_cost(instruction, state, machine_state, exec_env) do
      nil -> nil
      cost when is_integer(cost) -> cost + cost_mem(next_active_words) - cost_mem(machine_state.active_words)
    end
  end

  @doc """
  Returns the instruction cost for every possible instruction. This is defined
  in Appendix H of the Yellow Paper.

  ## Examples

      # TODO: Verify
      iex> EVM.Gas.instr_cost(:sstore, nil, nil, nil)
      0

      iex> EVM.Gas.instr_cost(:exp, nil, %EVM.MachineState{stack: [0, 0]}, nil)
      10

      # TODO: Verify
      iex> EVM.Gas.instr_cost(:exp, nil, %EVM.MachineState{stack: [0, 10241]}, nil)
      30

      iex> EVM.Gas.instr_cost(:jumpdest, nil, nil, nil)
      1

      iex> EVM.Gas.instr_cost(:blockhash, nil, nil, nil)
      20
  """
  @spec instr_cost(atom(), EVM.state, MachineState.t, ExecEnv.t) :: t | nil
  def instr_cost(:sstore, state, machine_state, _exec_env), do: cost_sstore(state, machine_state)
  def instr_cost(:exp, _state, machine_state, _exec_env) do
    case Enum.at(machine_state.stack, 1) do
      0 -> @g_exp
      s -> @g_exp + @g_expbyte * ( 1 + MathHelper.floor( MathHelper.log(s, 256) ) )
    end
  end

  def instr_cost(instr, _state, _machine_state, _exec_env) when instr in [:calldatacopy, :codecopy], do: 0
  def instr_cost(:extcodecopy, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:log0, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:log1, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:log2, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:log3, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:log4, _state, _machine_state, _exec_env), do: 0
  def instr_cost(call_instr, _state, _machine_state, _exec_env) when call_instr in [:call, :callcode, :delegatecall], do: 0
  def instr_cost(:suicide, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:create, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:sha3, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:jumpdest, _state, _machine_state, _exec_env), do: @g_jumpdest
  def instr_cost(:sload, _state, _machine_state, _exec_env), do: 0
  def instr_cost(w_zero_instr, _state, _machine_state, _exec_env) when w_zero_instr in @w_zero_instr, do: 0
  def instr_cost(w_base_instr, _state, _machine_state, _exec_env) when w_base_instr in @w_base_instr, do: 0
  def instr_cost(w_very_low_instr, _state, _machine_state, _exec_env) when w_very_low_instr in @w_very_low_instr, do: 0
  def instr_cost(w_low_instr, _state, _machine_state, _exec_env) when w_low_instr in @w_low_instr, do: 0
  def instr_cost(w_mid_instr, _state, _machine_state, _exec_env) when w_mid_instr in @w_mid_instr, do: 0
  def instr_cost(w_high_instr, _state, _machine_state, _exec_env) when w_high_instr in @w_high_instr, do: 0
  def instr_cost(w_extcode_instr, _state, _machine_state, _exec_env) when w_extcode_instr in @w_extcode_instr, do: 0
  def instr_cost(:balance, _state, _machine_state, _exec_env), do: 0
  def instr_cost(:blockhash, _state, _machine_state, _exec_env), do: @g_blockhash
  def instr_cost(_unknown_instr, _state, _machine_state, _exec_env), do: nil

  # Eq.(222)
  def cost_mem(active_words), do: 0

  @doc """
  Returns the cost of a call to `sstore`. This is defined
  in Appenfix H.2. of the Yellow Paper under the
  definition of SSTORE, referred to as `C_SSTORE`.

  # TODO: Implement and add examples
  """
  @spec cost_sstore(EVM.state, MachineState.t) :: t
  def cost_sstore(state, machine_state), do: 0

  def cost_call(state, machine_state), do: 0
  def cost_suicide(state, machine_state), do: 0

  @doc """
  Returns the gas cost for G_txdata{zero, nonzero} as defined in
  Appendix G (Fee Schedule) of the Yellow Paper.

  This implements `g_txdatazero` and `g_txdatanonzero`

  ## Examples

      iex> EVM.Gas.g_txdata(<<1, 2, 3, 0, 4, 5>>)
      5 * 68 + 4

      iex> EVM.Gas.g_txdata(<<0>>)
      4

      iex> EVM.Gas.g_txdata(<<0, 0>>)
      8

      iex> EVM.Gas.g_txdata(<<>>)
      0
  """
  @spec g_txdata(binary()) :: t
  def g_txdata(data) do
    for <<byte <- data>> do
      case byte do
        0 -> @g_txdatazero
        _ -> @g_txdatanonzero
      end
    end |> Enum.sum
  end

  @doc "Paid by all contract-creating transactions after the Homestead transition."
  @spec g_txcreate() :: t
  def g_txcreate, do: @g_create

  @doc "Paid for every transaction."
  @spec g_transaction() :: t
  def g_transaction, do: @g_transaction

end
