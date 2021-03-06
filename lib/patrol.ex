defmodule Patrol do
  @moduledoc """
  This module contains helpers for creating a sandbox environment
  for safely executing untrusted Elixir code.

  ## Creating a sandbox

  You can create multiple sandboxes for code execution.

  This is useful for implementing a different user access level sandboxes.

      iex> sb_users = %Sandbox{allowed_locals: []}
      iex> sb_root = %Sandbox{}
      iex> Patrol.eval("Enum.map(1..5, &(&1 + 3))", sb_root)
      [4, 5, 6, 7, 8]
      iex> Patrol.eval("Enum.map(File.ls("/"), &(File.rm!(&1)))", sb_user)
      ** (Patrol.PermissionError) You tripped the alarm! File.ls/1 is not allowed

  ## Creating self-contained sandboxed environments

  These self-contained sandboxes are anonymous functions that can run multiple
  codes with the same configuration.

  In most cases,especially for simplicity, this what you should use.

      iex> use Patrol
      iex> sb = Patrol.create_sandbox()
      iex> sb.("File.mkdir_p('/media/foo')")
      ** (Patrol.PermissionError) You tripped the alarm! File.mkdir_p('/media/foo') is not allowed

  """

  alias Patrol.Sandbox

  @io_device "/dev/null"
  @rand_min  17
  @rand_max  8765432369987654
  @memory_check_interval 1000

  defmacro __using__(_opts \\ []) do
    quote do
      require Patrol
      alias Patrol.Policy
      alias Patrol.Sandbox
      alias Patrol.PermissionError
    end
  end

  @doc """
  Walk the AST and catch blacklisted function calls
  Returns false if the AST contains non-allowed code, otherwise true

  ## Checks

  * 0 arity local functions
  * Functions defined with Kernel.def/2
  * Range size. Default range: to 0..1000
  * Calls to anonymous functions, eg. f.()
  * Remote function calls, such as System.version
  """
  defp is_safe?({{:., _, [module, fun]}, _, args}, sandbox) do
    module = Macro.expand(module, __ENV__)
    case Dict.get(sandbox.policy.allowed_non_local, module) do
      :all ->
        is_safe?(args, sandbox)
      {:all, except: methods} when is_list(methods) ->
        if fun in methods, do: false
      methods when is_list(methods) ->
        (fun in methods) and is_safe?(args, sandbox)
      _ ->
        false
    end
  end

  # anonymous function call, eg: sumup.(1..10)
  defp is_safe?({{:., _, [{_fun, _, _}]}, [], args}, sandbox) do
    is_safe?(args, sandbox)
  end

  # local calls
  defp is_safe?({fun, _, args}, sandbox) when is_atom(fun) and is_list(args) do
    (fun in sandbox.policy.allowed_local) and is_safe?(args, sandbox)
  end

  # limit range
  defp is_safe?({:.., _, [begin, last]}, sandbox) do
    (last - begin) <= sandbox.range_max and last < sandbox.range_max
  end

  defp is_safe?(_forms, _sandbox) do
    true
  end

  @doc """
  Convenience wrapper function around %Patrol.Sandbox{} for creating a sandboxed
  environment. It returns a self-contained module with an **eval** method for code
  evaluation

  ## Creating a self-contained sandbox

      iex> use Patrol
      iex> policy = %Policy{allowed_non_local: [Bitwise: :all, System: [:version]]}
      iex> sb = Patrol.create_sandbox([policy: policy, timeout: 2000])
      iex> sb.(System.version)
      { :ok, "0.14.2-dev" }


      iex> sb.eval("Code.loaded_files")
      ** (Patrol.PermissionError) You tripped the alarm! Code.loaded_files() is not allowed


  ## To run the same code in multiple sandboxes

      iex> use Patrol
      iex> sb_users = %Sandbox{allowed_locals: []}
      iex> sb_root = %Sandbox{}
      iex> Patrol.eval("System.cmd('cat /etc/passwd')"), sb_root)
      MySQL Server,,,:/nonexistent:/bin/false:/jenkins:x:117:128:Jenkins....

      iex> Patrol.eval("Enum.map(File.ls("/"), &(File.rm!(&1)))", sb_user)
      ** (Patrol.PermissionError) You tripped the alarm! File.rm/1 is not allowed
  """
  def create_sandbox(sandbox \\ %Sandbox{}) when is_map(sandbox) do
      fn code -> eval(code, sandbox) end
  end

  @doc """
  Evaluate the code within the sandbox

  ## Examples

      iex> use Patrol
      iex> sb = Patrol.create_sandbox()
      iex> sb.('File.mkdir_p("/media/foo")')
      ** (Patrol.PermissionError) You tripped the alarm! File.mkdir_p/1 is not allowed
  """
  def eval(code) do
    eval(code, %Sandbox{})
  end

  def eval(code, sandbox) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, forms} ->
        # proceed to actual code evaluation
        do_eval(forms, sandbox)

      {:error, {line, error, token}} ->
        :elixir_errors.parse(line, "patrol", error, token)
    end
  end

  # when passed a quoted expression
  def eval(code, sandbox) when is_tuple(code) do
    do_eval(code, sandbox)
  end

  defp do_eval(forms, sandbox) do
    unless is_safe?(forms, sandbox) do
      raise Patrol.PermissionError, Macro.to_string(forms)
    end

    {pid, ref} = {self, make_ref}
    Process.flag(:trap_exit, true)
    child_pid = create_eval_process(forms, sandbox, pid, ref)
    handle_eval_process(child_pid, sandbox, ref)
  end

  defp handle_eval_process(child_pid, sandbox, ref) do
    receive do
      {:ok, ref, {result, _ctx}} ->
        Process.exit(child_pid, :kill)
        unless nil?(sandbox.transform) do
          {:ok, sandbox.transform.(result)}
        else
          {:ok, result}
        end
      {:EXIT, _pid, {%CompileError{description: error_msg}, _err_stacktrace}} ->
        {:error, {:undef, {:local, error_msg}}}
      {:EXIT, _pid, {:undef, err_stacktrace}} ->
        {module, fun, args, _} = List.first err_stacktrace
        {:error, {:undef, {:remote, format_undef_err(module, fun, args)}}}
      {:EXIT, _pid, reason} when reason in [:normal, :killed] ->
        exit(:normal)
      error ->
        {:error, error}
    after
      sandbox.timeout ->
        # kill the child process and return
        {:error, {:timeout, Process.exit(child_pid, :kill)}}
    end
  end

  defp create_eval_process(forms, sandbox, parent_pid, ref) do
    proc =
    fn ->
      cond do
        is_pid(sandbox.io) && Process.alive?(sandbox.io) ->
          Process.group_leader(self, sandbox.io)
        nil?(sandbox.io) ->
          io_device = File.open!(@io_device, [:write, :read])
          Process.group_leader(self, io_device)
          sandbox.io == :stdio ->
          nil
        true ->
          raise """
                Expected a live process or :stdio as sandbox IO device,
                got '#{sandbox.io}'.
                """
      end

      # eval code
      env = :elixir.env_for_eval(delegate_locals_to: nil)
      send(parent_pid, {:ok, ref, Code.eval_quoted(forms, sandbox.context, env)})
    end
    # spawn process and return the pid
    spawn_link(proc)
  end

 defp format_undef_err(module, fun, args) do
   str_len = &String.length/1
   module = to_string(module)
   module_name = if String.starts_with?(module, "Elixir") do
                   String.slice(module, str_len.("Elixir."), str_len.(module))
                 end
   "undefined function: #{module_name}.#{fun}/#{length(args)}, called with: #{inspect args}"
 end

end
