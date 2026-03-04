defmodule Resiliency.RateLimiter.Server do
  @moduledoc false
  use GenServer

  # ETS row key for the mutable bucket state
  @bucket_key :bucket

  # --- Client API (called from caller process, not GenServer) ---

  @doc """
  Acquires `weight` tokens from the bucket. Hot path — pure ETS, no GenServer message.

  Returns `{:ok, :granted}` or `{:error, {:rate_limited, retry_after_ms}}`.
  """
  def acquire(name, weight) do
    {tab, rate, rate_per_ms, burst_size_f, _burst_size, on_reject} = config(name)
    # Convert weight to float once at the entry point; avoids two implicit int→float
    # coercions per call (in the >= comparison and the subtraction) inside the hot loop.
    do_acquire(tab, name, rate, rate_per_ms, burst_size_f, on_reject, weight * 1.0)
  end

  @doc """
  Returns current bucket stats. Direct ETS read — no GenServer message.
  """
  def get_stats(name) do
    {tab, rate, rate_per_ms, burst_size_f, burst_size, _on_reject} = config(name)

    [{@bucket_key, tokens, last_ts}] = :ets.lookup(tab, @bucket_key)
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - last_ts
    current_tokens = refill_tokens(tokens, elapsed_ms, rate_per_ms, burst_size_f)

    %{tokens: current_tokens, rate: rate, burst_size: burst_size}
  end

  # --- GenServer (table owner + reset) ---

  def start_link(opts) do
    # Validate eagerly — raises KeyError/:name missing, or ArgumentError for bad values
    validate_opts!(opts)
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_name(name))
  end

  @doc false
  def via_name(name), do: :"#{__MODULE__}.#{inspect(name)}"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    rate = Keyword.fetch!(opts, :rate)
    burst_size = Keyword.fetch!(opts, :burst_size)
    on_reject = Keyword.get(opts, :on_reject)

    # Pre-compute derived constants once; avoids repeated arithmetic in the hot path.
    burst_size_f = burst_size * 1.0
    # rate_per_ms eliminates a float division (rate / 1000.0) from every refill call.
    rate_per_ms = rate / 1000.0

    # Create an unnamed public ETS table; the ref is stored in persistent_term
    # so callers can reach it without going through the GenServer process.
    tab = :ets.new(:rl_bucket, [:set, :public, read_concurrency: true])

    now = System.monotonic_time(:millisecond)
    :ets.insert(tab, {@bucket_key, burst_size_f, now})

    # Store table ref + immutable config in persistent_term — zero-cost reads.
    # Config tuple layout: {tab, rate, rate_per_ms, burst_size_f, burst_size, on_reject}
    #   rate        – tokens/second, returned by get_stats
    #   rate_per_ms – rate/1000.0, used in refill math (eliminates per-call division)
    #   burst_size_f – float, used in min() cap without int→float coercion
    #   burst_size  – integer, returned by get_stats
    :persistent_term.put(
      config_key(name),
      {tab, rate, rate_per_ms, burst_size_f, burst_size, on_reject}
    )

    {:ok, %{name: name, tab: tab, burst_size_f: burst_size_f}}
  end

  @impl true
  def handle_call(:reset, _from, %{tab: tab, burst_size_f: burst_size_f} = state) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(tab, {@bucket_key, burst_size_f, now})
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{name: name, tab: tab}) do
    :ets.delete(tab)
    :persistent_term.erase(config_key(name))
    :ok
  end

  # --- Internal hot path ---

  # CAS retry loop: read → compute refill → attempt select_replace → retry on conflict.
  # weight_f is pre-converted to float by acquire/2 to avoid per-iteration coercions.
  defp do_acquire(tab, name, rate, rate_per_ms, burst_size_f, on_reject, weight_f, retries \\ 0) do
    [{@bucket_key, old_tokens, old_ts}] = :ets.lookup(tab, @bucket_key)

    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - old_ts
    new_tokens = refill_tokens(old_tokens, elapsed_ms, rate_per_ms, burst_size_f)

    if new_tokens >= weight_f do
      # Attempt CAS: only replace if the row still matches what we read
      updated =
        :ets.select_replace(tab, [
          {{@bucket_key, old_tokens, old_ts}, [], [{{@bucket_key, new_tokens - weight_f, now}}]}
        ])

      if updated == 1 do
        {:ok, :granted}
      else
        # Another caller won the CAS — retry with fresh state.
        # The limit of 100 far exceeds the maximum realistic scheduler concurrency
        # (BEAM schedulers = CPU cores, typically ≤ 64). Hitting it indicates a bug
        # in the ETS table, not normal high load.
        if retries >= 100 do
          raise "rate limiter #{inspect(name)}: CAS retry limit exceeded — pathological contention"
        end

        do_acquire(tab, name, rate, rate_per_ms, burst_size_f, on_reject, weight_f, retries + 1)
      end
    else
      # Rejected — update tokens + timestamp to avoid double-counting elapsed time
      # on the next call. Unlike the grant path, a race here is harmless: if another
      # caller already wrote a fresher state, our update is simply lost, and the next
      # reader will compute from that fresher baseline. We use update_element (no match
      # spec allocation) rather than select_replace because we don't need CAS semantics.
      :ets.update_element(tab, @bucket_key, [{2, new_tokens}, {3, now}])

      deficit = weight_f - new_tokens
      retry_after_ms = max(1, ceil(deficit / rate * 1000))
      fire_callback(on_reject, name)
      {:error, {:rate_limited, retry_after_ms}}
    end
  end

  # --- Helpers ---

  defp config_key(name), do: {__MODULE__, :config, name}

  defp config(name) do
    case :persistent_term.get(config_key(name), nil) do
      nil -> raise ArgumentError, "no rate limiter registered under name: #{inspect(name)}"
      config -> config
    end
  end

  # Computes the new token count after a lazy refill, capped at the burst ceiling.
  # rate_per_ms is rate/1000.0, pre-computed at init to avoid a division per call.
  defp refill_tokens(tokens, elapsed_ms, rate_per_ms, burst_size_f) do
    min(burst_size_f, tokens + elapsed_ms * rate_per_ms)
  end

  defp fire_callback(nil, _name), do: :ok

  defp fire_callback(cb, name) do
    cb.(name)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- Validation ---

  defp validate_opts!(opts) do
    _ = Keyword.fetch!(opts, :name)
    rate = Keyword.fetch!(opts, :rate)
    burst_size = Keyword.fetch!(opts, :burst_size)
    on_reject = Keyword.get(opts, :on_reject)

    unless is_number(rate) and rate > 0 do
      raise ArgumentError, "rate must be a positive number, got: #{inspect(rate)}"
    end

    unless is_integer(burst_size) and burst_size >= 1 do
      raise ArgumentError, "burst_size must be a positive integer, got: #{inspect(burst_size)}"
    end

    if on_reject != nil and not is_function(on_reject, 1) do
      raise ArgumentError, "on_reject must be a function of arity 1, got: #{inspect(on_reject)}"
    end
  end
end
