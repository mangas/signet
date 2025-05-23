defmodule Signet.VM do
  @moduledoc ~S"""
  An Ethereum VM in Signet, that can only execute pure functions.
  """
  use Signet.Hex

  import Bitwise

  require Logger

  alias Signet.Assembly

  @type signed :: integer()
  @type unsigned :: non_neg_integer()

  @type opcode :: Signet.Assembly.opcode()
  @type code :: [opcode()]
  @type word :: <<_::256>>
  @type address :: <<_::160>>
  @type ffis :: %{address() => code()}
  @type context_result :: {:ok, Context.t()} | {:error, vm_error()}
  @type exec_opts :: [
          callvalue: integer(),
          ffis: ffis()
        ]
  @type vm_error ::
          :pc_out_of_bounds
          | :value_overflow
          | :stack_underflow
          | :signed_integer_out_of_bounds
          | :out_of_memory
          | :invalid_operation
          | {:unknown_ffi, address()}
          | {:invalid_push, integer(), binary()}
          | {:impure, opcode()}
          | {:not_implemented, opcode()}

  @word_one <<1::256>>
  @word_zero <<0::256>>
  @two_pow_256 2 ** 256
  @max_uint256 @two_pow_256 - 1
  @gas_amount 4_000_000

  defmodule FFIs do
    def log_ffi(args) do
      case Signet.Contract.IConsole.decode_call(args) do
        {:ok, f, values} ->
          IO.puts(
            "console.#{f}: #{inspect(values, limit: :infinity, printable_limit: :infinity)}"
          )

        _ ->
          nil
      end

      {:return, <<>>}
    end
  end

  @builtin_ffis %{
    ~h[0x000000000000000000636F6e736F6c652e6c6f67] => &FFIs.log_ffi/1
  }

  defmodule Input do
    defstruct [:calldata, :value]

    @type t :: %__MODULE__{
            calldata: binary(),
            value: Signet.VM.unsigned()
          }
  end

  defmodule Context do
    defstruct [
      :code,
      :code_encoded,
      :op_map,
      :pc,
      :halted,
      :stack,
      :memory,
      :tstorage,
      :reverted,
      # TODO: Should return data be a stack
      :return_data,
      :ffis
    ]

    @type op_map :: %{integer() => Signet.VM.opcode()}
    @type t :: %__MODULE__{
            code: Signet.VM.code(),
            code_encoded: binary(),
            op_map: op_map(),
            pc: integer(),
            halted: binary(),
            stack: [binary()],
            memory: binary(),
            tstorage: %{binary() => binary()},
            reverted: boolean(),
            return_data: binary(),
            ffis: Signet.VM.ffis()
          }

    @spec init_from(Signet.VM.code(), Signet.VM.ffis()) :: t()
    def init_from(code, ffis) do
      code_encoded = Signet.Assembly.assemble(code)

      %__MODULE__{
        code: code,
        code_encoded: code_encoded,
        op_map: build_op_map(code),
        pc: 0,
        halted: false,
        stack: [],
        memory: <<>>,
        tstorage: %{},
        reverted: false,
        return_data: <<>>,
        ffis: ffis
      }
    end

    @spec fetch_ffi(t(), Signet.VM.address()) ::
            {:ok, Signet.VM.code()} | {:error, Signet.VM.vm_error()}
    def fetch_ffi(context, address) do
      with :error <- Map.fetch(context.ffis, address) do
        {:error, {:unknown_ffi, address}}
      end
    end

    @spec build_op_map(Signet.VM.code()) :: op_map()
    defp build_op_map(code) do
      Enum.reduce(code, {0, %{}}, fn operation, {pc, op_map} ->
        new_pc = pc + Assembly.opcode_size(operation)
        {new_pc, Map.put(op_map, pc, operation)}
      end)
      |> elem(1)
    end

    defp show_hex(i, padding \\ nil) do
      hex = Integer.to_string(i, 16)

      if padding == nil do
        hex
      else
        String.pad_leading(hex, padding, "0")
      end
    end

    def show_stack(stack) do
      hex_length = String.length(show_hex(Enum.count(stack) * 32))

      Enum.with_index(Enum.reverse(stack), fn el, i ->
        "\t#{show_hex(i * 32, hex_length)} #{to_hex(el)}"
      end)
      |> Enum.join("\n")
    end

    def show(context) do
      [
        "pc=#{context.pc}",
        "stack:",
        show_stack(context.stack)
      ]
      |> Enum.join("\n")
    end
  end

  defmodule ExecutionResult do
    defstruct [:stack, :reverted, :return_data]

    @type t :: %__MODULE__{
            stack: [binary()],
            reverted: boolean(),
            return_data: binary()
          }

    @spec from_context(Signet.VM.Context.t()) :: t()
    def from_context(context) do
      %__MODULE__{
        stack: context.stack,
        reverted: context.reverted,
        return_data: context.return_data
      }
    end
  end

  @spec get_operation(Context.t()) :: {:ok, opcode()} | {:error, vm_error()}
  defp get_operation(context) do
    with :error <- Map.fetch(context.op_map, context.pc) do
      {:error, :pc_out_of_bounds}
    end
  end

  @spec pad_to_word(binary()) :: {:ok, <<_::256>>} | {:error, vm_error()}
  def pad_to_word(bin) when is_binary(bin) do
    if byte_size(bin) > 32 do
      {:error, :value_overflow}
    else
      padded_bin = :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
      {:ok, padded_bin}
    end
  end

  @spec pop(Context.t()) :: {:ok, Context.t(), word()} | {:error, vm_error()}
  def pop(context) do
    case context.stack do
      [x | rest] ->
        {:ok, %{context | stack: rest}, x}

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec peek(Context.t(), integer()) :: {:ok, word()} | {:error, vm_error()}
  def peek(context, n) do
    case Enum.at(context.stack, n) do
      nil ->
        {:error, :stack_underflow}

      x ->
        {:ok, x}
    end
  end

  @spec pop_unsigned(Context.t()) ::
          {:ok, Context.t(), unsigned()} | {:error, vm_error()}
  def pop_unsigned(context) do
    case context.stack do
      [x_enc | rest] ->
        with {:ok, x} <- word_to_uint(x_enc) do
          {:ok, %{context | stack: rest}, x}
        end

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec pop2(Context.t()) :: {:ok, Context.t(), word(), word()} | {:error, vm_error()}
  def pop2(context) do
    case context.stack do
      [x, y | rest] ->
        {:ok, %{context | stack: rest}, x, y}

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec pop2_unsigned(Context.t()) ::
          {:ok, Context.t(), unsigned(), unsigned()} | {:error, vm_error()}
  def pop2_unsigned(context) do
    case context.stack do
      [x_enc, y_enc | rest] ->
        with {:ok, x} <- word_to_uint(x_enc),
             {:ok, y} <- word_to_uint(y_enc) do
          {:ok, %{context | stack: rest}, x, y}
        end

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec pop3_unsigned(Context.t()) ::
          {:ok, Context.t(), unsigned(), unsigned(), unsigned()} | {:error, vm_error()}
  def pop3_unsigned(context) do
    case context.stack do
      [x_enc, y_enc, z_enc | rest] ->
        with {:ok, x} <- word_to_uint(x_enc),
             {:ok, y} <- word_to_uint(y_enc),
             {:ok, z} <- word_to_uint(z_enc) do
          {:ok, %{context | stack: rest}, x, y, z}
        end

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec pop2_unsigned_word(Context.t()) ::
          {:ok, Context.t(), unsigned(), word()} | {:error, vm_error()}
  def pop2_unsigned_word(context) do
    case context.stack do
      [x_enc, y_enc | rest] ->
        with {:ok, x} <- word_to_uint(x_enc) do
          {:ok, %{context | stack: rest}, x, y_enc}
        end

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec pop3(Context.t()) :: {:ok, Context.t(), word(), word(), word()} | {:error, vm_error()}
  def pop3(context) do
    case context.stack do
      [x, y, z | rest] ->
        {:ok, %{context | stack: rest}, x, y, z}

      [] ->
        {:error, :stack_underflow}
    end
  end

  @spec push_word(Context.t(), word()) :: {:ok, Context.t()} | {:error, vm_error()}
  def push_word(context, v) when is_binary(v) and bit_size(v) == 256 do
    if Enum.count(context.stack) == 1024 do
      {:error, :stack_overflow}
    else
      {:ok, %{context | stack: [v | context.stack]}}
    end
  end

  @spec word_to_uint(binary()) :: {:ok, unsigned()} | {:error, vm_error()}
  def word_to_uint(v) when is_binary(v) do
    # TODO: Check for overflow?
    {:ok, :binary.decode_unsigned(v)}
  end

  @spec uint_to_word(unsigned()) :: {:ok, binary()} | {:error, vm_error()}
  def uint_to_word(v) when is_integer(v) do
    enc = :binary.encode_unsigned(v)

    pad_to_word(enc)
  end

  @spec word_to_sint(binary()) :: {:ok, signed()} | {:error, vm_error()}
  def word_to_sint(<<value::signed-size(256)>>) do
    {:ok, value}
  end

  def word_to_sint(_) do
    {:error, :signed_integer_out_of_bounds}
  end

  @spec sint_to_word(signed()) :: {:ok, binary()} | {:error, atom()}
  def sint_to_word(v) when is_integer(v) do
    min_value = -2 ** 255
    max_value = 2 ** 255 - 1

    if v >= min_value and v <= max_value do
      {:ok, <<v::signed-size(256)>>}
    else
      {:error, :signed_integer_out_of_bounds}
    end
  end

  @spec pop2_and_push(Context.t(), (word(), word() -> {:ok, word()})) :: context_result()
  defp pop2_and_push(context, fun) do
    with {:ok, context, a, b} <- pop2(context),
         {:ok, v_enc} <- fun.(a, b) do
      push_word(context, v_enc)
    end
  end

  @spec unsigned_op1(Context.t(), (unsigned() -> unsigned())) :: context_result()
  defp unsigned_op1(context, fun) do
    with {:ok, context, a} <- pop(context),
         {:ok, a_int} <- word_to_uint(a),
         v <- fun.(a_int),
         {:ok, v_enc} <- uint_to_word(v) do
      push_word(context, v_enc)
    end
  end

  @spec unsigned_op2(Context.t(), (unsigned(), unsigned() -> unsigned())) :: context_result()
  defp unsigned_op2(context, fun) do
    with {:ok, context, a, b} <- pop2(context),
         {:ok, a_int} <- word_to_uint(a),
         {:ok, b_int} <- word_to_uint(b),
         v <- fun.(a_int, b_int),
         {:ok, v_enc} <- uint_to_word(v) do
      push_word(context, v_enc)
    end
  end

  @spec unsigned_op3(Context.t(), (unsigned(), unsigned(), unsigned() -> unsigned())) ::
          context_result()
  defp unsigned_op3(context, fun) do
    with {:ok, context, a, b, c} <- pop3(context),
         {:ok, a_int} <- word_to_uint(a),
         {:ok, b_int} <- word_to_uint(b),
         {:ok, c_int} <- word_to_uint(c),
         v <- fun.(a_int, b_int, c_int),
         {:ok, v_enc} <- uint_to_word(v) do
      push_word(context, v_enc)
    end
  end

  @spec signed_op2(Context.t(), (signed(), signed() -> signed())) :: context_result()
  defp signed_op2(context, fun) do
    with {:ok, context, a, b} <- pop2(context),
         {:ok, a_int} <- word_to_sint(a),
         {:ok, b_int} <- word_to_sint(b),
         v <- fun.(a_int, b_int),
         {:ok, v_enc} <- sint_to_word(v) do
      push_word(context, v_enc)
    end
  end

  @spec unsigned_signed_op2(Context.t(), (unsigned(), signed() -> signed())) :: context_result()
  defp unsigned_signed_op2(context, fun) do
    with {:ok, context, a, b} <- pop2(context),
         {:ok, a_int} <- word_to_uint(a),
         {:ok, b_int} <- word_to_sint(b),
         v <- fun.(a_int, b_int),
         {:ok, v_enc} <- sint_to_word(v) do
      push_word(context, v_enc)
    end
  end

  @spec push_n(Context.t(), integer(), binary()) :: context_result()
  defp push_n(context, n, v) do
    if byte_size(v) > n do
      {:error, {:invalid_push, n, v}}
    else
      with {:ok, word_padded} <- pad_to_word(v) do
        push_word(context, word_padded)
      end
    end
  end

  @spec inc_pc(context_result(), opcode()) :: context_result()
  def inc_pc(context_result, operation) do
    with {:ok, context} <- context_result do
      # Note: we can increment even when there's a jump, since either
      # we'll increment over the jump _or_ the jumpdest
      {:ok, %{context | pc: context.pc + Assembly.opcode_size(operation)}}
    end
  end

  @spec cap_to_range(integer(), integer(), integer()) :: integer()
  def cap_to_range(x, min, max) do
    cond do
      x > max ->
        max

      x < min ->
        min

      true ->
        x
    end
  end

  defmodule Memory do
    # 10MB
    @max_memory 10_000_000

    @spec expand_memory(binary(), Signet.VM.unsigned()) ::
            {:ok, binary()} | {:error, Signet.VM.vm_error()}
    defp expand_memory(memory, total_size) do
      memory_size = byte_size(memory)

      cond do
        total_size > @max_memory ->
          {:error, :out_of_memory}

        memory_size >= total_size ->
          {:ok, memory}

        true ->
          padding = total_size - memory_size

          {:ok, memory <> :binary.copy(<<0x0>>, padding)}
      end
    end

    @spec read_memory(binary(), Signet.VM.unsigned(), Signet.VM.unsigned()) ::
            {:ok, binary(), binary()} | {:error, Signet.VM.vm_error()}
    def read_memory(memory, index, count) do
      with {:ok, memory_expanded} <- expand_memory(memory, index + count) do
        <<_::binary-size(index), res::binary-size(count), _::binary>> = memory_expanded
        {:ok, memory_expanded, res}
      end
    end

    @spec write_memory(Signet.VM.Context.t(), Signet.VM.unsigned(), binary()) ::
            {:ok, Signet.VM.Context.t()} | {:error, Signet.VM.vm_error()}
    def write_memory(context, offset, value) do
      value_size = byte_size(value)

      with {:ok, memory_expanded} <- expand_memory(context.memory, offset + value_size) do
        <<start::binary-size(offset), _::binary-size(value_size), final::binary>> =
          memory_expanded

        memory_final = <<start::binary, value::binary, final::binary>>
        {:ok, %{context | memory: memory_final}}
      end
    end
  end

  defmodule Operations do
    def sign_extend(b, x) do
      with {:ok, b_int} <- Signet.VM.word_to_uint(b) do
        if b_int >= 31 do
          # No sign extend beyond 32nd bit
          {:ok, x}
        else
          val_len = b_int + 1
          <<_::binary-size(32 - val_len), low_word::binary-size(val_len)>> = x

          if Bitwise.band(Bitwise.bsr(:binary.decode_unsigned(low_word), 8 * val_len - 1), 1) == 1 do
            # Fill in top bits
            {:ok, :binary.copy(<<0xFF>>, 32 - val_len) <> low_word}
          else
            # Positive
            {:ok, x}
          end
        end
      end
    end

    def get_byte(i, x) do
      with {:ok, i} <- Signet.VM.word_to_uint(i) do
        unless i < 32 do
          {:ok, <<0::256>>}
        else
          <<_::binary-size(i), word::binary-size(1), _::binary-size(31 - i)>> = x
          Signet.VM.pad_to_word(word)
        end
      end
    end
  end

  # Calls
  defp static_call(context) do
    with {:ok, context, _gas, address, args_offset, args_size, ret_offset, ret_size} <-
           pop_call_args(context),
         {:ok, memory_expanded, args} <-
           Memory.read_memory(context.memory, args_offset, args_size),
         context <- %{context | memory: memory_expanded},
         {:ok, ffi} <- Context.fetch_ffi(context, address) do
      case ffi.(args) do
        {:return, return_data} ->
          return_data_to_copy =
            if byte_size(return_data) >= ret_size do
              # Take left N bytes
              <<v::binary-size(ret_size), _::binary>> = return_data

              v
            else
              # Pad right with zeros
              return_data <> :binary.copy(<<0x0>>, ret_size - byte_size(return_data))
            end

          with {:ok, context} <-
                 context
                 |> Map.put(:return_data, return_data)
                 |> Memory.write_memory(
                   ret_offset,
                   return_data_to_copy
                 ) do
            push_word(context, @word_one)
          end

        {:revert, revert} ->
          context
          |> Map.merge(%{return_data: revert, halted: true, reverted: true})
          |> push_word(@word_zero)
      end
    end
  end

  defp pop_call_args(context) do
    with {:ok, context, gas} <- pop_unsigned(context),
         {:ok, context, address_word} <- pop(context),
         {:ok, context, args_offset} <- pop_unsigned(context),
         {:ok, context, args_size} <- pop_unsigned(context),
         {:ok, context, ret_offset} <- pop_unsigned(context),
         {:ok, context, ret_size} <- pop_unsigned(context) do
      {:ok, context, gas, word_to_address(address_word), args_offset, args_size, ret_offset,
       ret_size}
    end
  end

  defp word_to_address(word) do
    <<_preface::binary-size(12), address::binary-size(20)>> = word

    address
  end

  @spec run_single_op(Context.t(), Input.t(), Keyword.t()) :: context_result()
  def run_single_op(context, input, opts) do
    if opts[:verbose] do
      Logger.debug(Context.show(context))
    end

    with {:ok, operation} <- get_operation(context) do
      if opts[:verbose] do
        Logger.debug("Operation: #{Signet.Assembly.show_opcode(operation)}")
      end

      case operation do
        :stop ->
          {:ok, %{context | return_data: <<>>, halted: true}}

        :add ->
          unsigned_op2(context, &rem(&1 + &2, @two_pow_256))

        :sub ->
          unsigned_op2(context, &rem(@two_pow_256 + &1 - &2, @two_pow_256))

        :mul ->
          unsigned_op2(context, &rem(&1 * &2, @two_pow_256))

        :div ->
          unsigned_op2(context, &if(&2 == 0, do: 0, else: Integer.floor_div(&1, &2)))

        :sdiv ->
          signed_op2(context, &if(&2 == 0, do: 0, else: Integer.floor_div(&1, &2)))

        :mod ->
          unsigned_op2(context, &if(&2 == 0, do: 0, else: rem(&1, &2)))

        :smod ->
          signed_op2(context, &if(&2 == 0, do: 0, else: rem(&1, &2)))

        :addmod ->
          unsigned_op3(context, &if(&3 == 0, do: 0, else: rem(&1 + &2, &3)))

        :mulmod ->
          unsigned_op3(context, &if(&3 == 0, do: 0, else: rem(&1 * &2, &3)))

        :exp ->
          unsigned_op2(context, &rem(&1 ** &2, @two_pow_256))

        :signextend ->
          pop2_and_push(context, &Operations.sign_extend/2)

        :lt ->
          unsigned_op2(context, &if(&1 < &2, do: 1, else: 0))

        :gt ->
          unsigned_op2(context, &if(&1 > &2, do: 1, else: 0))

        :slt ->
          signed_op2(context, &if(&1 < &2, do: 1, else: 0))

        :sgt ->
          signed_op2(context, &if(&1 > &2, do: 1, else: 0))

        :eq ->
          unsigned_op2(context, &if(&1 == &2, do: 1, else: 0))

        :iszero ->
          unsigned_op1(context, &if(&1 == 0, do: 1, else: 0))

        :and ->
          unsigned_op2(context, &Bitwise.band(&1, &2))

        :or ->
          unsigned_op2(context, &Bitwise.bor(&1, &2))

        :xor ->
          unsigned_op2(context, &Bitwise.bxor(&1, &2))

        :not ->
          unsigned_op1(context, &Bitwise.bxor(&1, @max_uint256))

        :byte ->
          pop2_and_push(context, &Operations.get_byte/2)

        :shl ->
          unsigned_op2(context, &rem(Bitwise.bsl(&2, cap_to_range(&1, 0, 255)), @two_pow_256))

        :shr ->
          unsigned_op2(context, &Bitwise.bsr(&2, cap_to_range(&1, 0, 255)))

        :sar ->
          unsigned_signed_op2(context, &(&2 >>> cap_to_range(&1, 0, 255)))

        :sha3 ->
          with {:ok, context, offset, size} <- pop2_unsigned(context),
               {:ok, memory_expanded, data} <- Memory.read_memory(context.memory, offset, size) do
            push_word(%{context | memory: memory_expanded}, Signet.Hash.keccak(data))
          end

        :callvalue ->
          with {:ok, value} <- uint_to_word(input.value) do
            push_word(context, value)
          end

        :calldataload ->
          with {:ok, context, i} <- pop_unsigned(context),
               {:ok, _, res} <- Memory.read_memory(input.calldata, i, 32) do
            push_word(context, res)
          end

        :calldatasize ->
          with {:ok, calldata_size} <- uint_to_word(byte_size(input.calldata)) do
            push_word(context, calldata_size)
          end

        :calldatacopy ->
          with {:ok, context, dest_offset, offset, size} <- pop3_unsigned(context),
               {:ok, _, calldata} <- Memory.read_memory(input.calldata, offset, size) do
            Memory.write_memory(context, dest_offset, calldata)
          end

        :codesize ->
          with {:ok, codesize} <- uint_to_word(byte_size(context.code_encoded)) do
            push_word(context, codesize)
          end

        :codecopy ->
          with {:ok, context, dest_offset, offset, size} <- pop3_unsigned(context),
               {:ok, _, code} <- Memory.read_memory(context.code_encoded, offset, size) do
            Memory.write_memory(context, dest_offset, code)
          end

        :pop ->
          with {:ok, context, _} <- pop(context) do
            {:ok, context}
          end

        :mload ->
          with {:ok, context, i} <- pop_unsigned(context),
               {:ok, memory_expanded, res} <- Memory.read_memory(context.memory, i, 32) do
            push_word(%{context | memory: memory_expanded}, res)
          end

        :mstore ->
          with {:ok, context, offset, value} <- pop2_unsigned_word(context) do
            Memory.write_memory(context, offset, value)
          end

        :mstore8 ->
          with {:ok, context, offset, value} <- pop2_unsigned_word(context) do
            <<_::binary-size(31), byte::binary>> = value
            Memory.write_memory(context, offset, byte)
          end

        :jump ->
          with {:ok, context, jump_dest} <- pop_unsigned(context) do
            case Map.get(context.op_map, jump_dest) do
              :jumpdest ->
                {:ok, %{context | pc: jump_dest}}

              _ ->
                {:error, :invalid_jump_dest}
            end
          end

        :jumpi ->
          with {:ok, context, jump_dest, b} <- pop2_unsigned(context) do
            if b == 0 do
              {:ok, context}
            else
              case Map.get(context.op_map, jump_dest) do
                :jumpdest ->
                  {:ok, %{context | pc: jump_dest}}

                _ ->
                  {:error, :invalid_jump_dest}
              end
            end
          end

        :pc ->
          with {:ok, pc} <- uint_to_word(context.pc) do
            push_word(context, pc)
          end

        :msize ->
          with {:ok, memory_sz} <- uint_to_word(byte_size(context.memory)) do
            push_word(context, memory_sz)
          end

        :gas ->
          with {:ok, gas_amount} <- uint_to_word(@gas_amount) do
            push_word(context, gas_amount)
          end

        :jumpdest ->
          {:ok, context}

        :tload ->
          with {:ok, context, res} <- pop_unsigned(context) do
            push_word(context, Map.get(context.tstorage, res, <<0::256>>))
          end

        :tstore ->
          with {:ok, context, key, value} <- pop2_unsigned_word(context) do
            {:ok, %{context | tstorage: Map.put(context.tstorage, key, value)}}
          end

        :mcopy ->
          with {:ok, context, dest_offset, offset, size} <- pop3_unsigned(context),
               {:ok, memory_expanded, value} <- Memory.read_memory(context.memory, offset, size) do
            Memory.write_memory(%{context | memory: memory_expanded}, dest_offset, value)
          end

        {:push, n, v} ->
          push_n(context, n, v)

        {:dup, n} ->
          with {:ok, val} <- peek(context, n - 1) do
            push_word(context, val)
          end

        {:swap, n} ->
          with {:ok, high} <- peek(context, n),
               {:ok, low} <- peek(context, 0) do
            stack =
              context.stack
              |> List.replace_at(n, low)
              |> List.replace_at(0, high)

            {:ok, %{context | stack: stack}}
          end

        :return ->
          with {:ok, context, offset, size} <- pop2_unsigned(context) do
            with {:ok, memory_expanded, return_data} <-
                   Memory.read_memory(context.memory, offset, size) do
              {:ok, %{context | memory: memory_expanded, return_data: return_data, halted: true}}
            end
          end

        :revert ->
          with {:ok, context, offset, size} <- pop2_unsigned(context) do
            with {:ok, memory_expanded, return_data} <-
                   Memory.read_memory(context.memory, offset, size) do
              {:ok,
               %{
                 context
                 | memory: memory_expanded,
                   return_data: return_data,
                   halted: true,
                   reverted: true
               }}
            end
          end

        {:invalid, _} ->
          {:error, :invalid_operation}

        :staticcall ->
          static_call(context)

        :returndatasize ->
          with {:ok, return_data_size} <- uint_to_word(byte_size(context.return_data)) do
            push_word(context, return_data_size)
          end

        :returndatacopy ->
          with {:ok, context, dest_offset, offset, size} <- pop3_unsigned(context),
               {:ok, _, calldata} <- Memory.read_memory(context.return_data, offset, size) do
            Memory.write_memory(context, dest_offset, calldata)
          end

        op
        when op in [
               :address,
               :balance,
               :origin,
               :caller,
               :gasprice,
               :extcodesize,
               :extcodecopy,
               :extcodehash,
               :blockhash,
               :coinbase,
               :timestamp,
               :number,
               :prevrandao,
               :gaslimit,
               :chainid,
               :selfbalance,
               :basefee,
               :blobhash,
               :blobbasefee,
               :sload,
               :sstore,
               :log,
               :create,
               :call,
               :callcode,
               :delegatecall,
               :create2,
               :selfdestruct
             ] ->
          {:error, {:impure, operation}}

        _ ->
          {:error, {:not_implemented, operation}}
      end
      |> inc_pc(operation)
    end
  end

  @spec run_code(Context.t(), Input.t(), Keyword.t()) ::
          {:ok, ExecutionResult.t()} | {:error, vm_error()}
  defp run_code(context, input, opts \\ []) do
    case run_single_op(context, input, opts) do
      {:ok, context = %Context{halted: true}} ->
        {:ok, ExecutionResult.from_context(context)}

      {:ok, context} ->
        run_code(context, input)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc ~S"""
  Executes the Ethereum Virtual Machine (EVM) with the given `code` and `input`.

  **Parameters**
    - `code`: The bytecode to be executed, either as a `binary` or decoded.
    - `calldata`: The call data for the execution.
    - `opts`: Execution options (see below)

  **Options**
    - `:callvalue`: value passed as callvalue for the execution.
    - `:ffis`: A mapping of address to functions to run as natively implemented ffis

  Returns the result of the execution.
  """
  @spec exec(code() | binary(), binary(), exec_opts()) ::
          {:ok, ExecutionResult.t()} | {:error, vm_error()}
  def exec(code, calldata, opts \\ [])

  def exec(code, calldata, opts) when is_binary(code) do
    exec(Assembly.disassemble(code), calldata, opts)
  end

  def exec(code, calldata, opts) when is_list(code) do
    run_code(
      Context.init_from(code, Map.merge(@builtin_ffis, Keyword.get(opts, :ffis, %{}))),
      %Input{
        calldata: calldata,
        value: Keyword.get(opts, :callvalue, 0)
      },
      opts
    )
  end

  defmodule VmError do
    defexception message: "VmError"
  end

  @doc ~S"""
  Runs the given EVM, returning the `RETURN` data or the `REVERT` data.

  Raises on any other exceptional state.

  **Parameters**
    - `code`: The bytecode to be executed, either as a `binary` or decoded.
    - `calldata`: The call data for the execution.
    - `opts`: Execution options (see below)

  **Options**
    - `:callvalue`: value passed as callvalue for the execution.
    - `:ffis`: A mapping of address to functions to run as natively implemented ffis
  """
  @spec exec_call(code() | binary(), binary(), exec_opts()) ::
          {:ok, binary()} | {:revert, binary()}
  def exec_call(code, calldata, opts \\ []) do
    case exec(code, calldata, opts) do
      {:ok, %ExecutionResult{reverted: reverted, return_data: return_data}} ->
        if reverted do
          {:revert, return_data}
        else
          {:ok, return_data}
        end

      {:error, error} ->
        raise VmError, "VmError: #{inspect(error)}"
    end
  end
end
