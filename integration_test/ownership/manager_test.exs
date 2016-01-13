defmodule ManagerTest do
  use ExUnit.Case, async: true

  alias TestPool, as: P
  alias TestAgent, as: A
  alias DBConnection.Ownership

  test "requires explicit checkout on manual mode" do
    {:ok, pool} = start_pool()
    refute_checked_out pool
    assert Ownership.ownership_checkout(pool, []) == :ok
    assert_checked_out pool
    assert Ownership.ownership_checkin(pool, []) == :ok
    refute_checked_out pool
    assert Ownership.ownership_checkin(pool, []) == :not_found
  end

  test "does not require explicit checkout on automatic mode" do
    {:ok, pool} = start_pool()
    refute_checked_out pool
    assert Ownership.ownership_mode(pool, :auto, []) == :ok
    assert_checked_out pool
  end

  test "returns {:already, status} when already checked out" do
    {:ok, pool} = start_pool()

    assert Ownership.ownership_checkout(pool, []) ==
           :ok
    assert Ownership.ownership_checkout(pool, []) ==
           {:already, :owner}
  end

  test "connection may be shared with other processes" do
    {:ok, pool} = start_pool()
    parent = self()

    Task.await Task.async fn ->
      assert Ownership.ownership_allow(pool, parent, self(), []) == :not_found
    end

    :ok = Ownership.ownership_checkout(pool, [])
    assert Ownership.ownership_allow(pool, self(), self(), []) ==
           {:already, :owner}

    Task.await Task.async fn ->
      assert Ownership.ownership_allow(pool, parent, self(), []) ==
             :ok
      assert Ownership.ownership_allow(pool, parent, self(), []) ==
             {:already, :allowed}

      assert Ownership.ownership_checkin(pool, []) == :not_owner

      parent = self()
      Task.await Task.async fn ->
        assert Ownership.ownership_allow(pool, parent, self(), []) ==
               :not_owner
      end
    end
  end

  test "owner's crash automatically checks the connection back in" do
    {:ok, pool} = start_pool()
    parent = self()

    pid = spawn_link(fn() ->
      assert_receive :refute_checkout
      refute_checked_out pool
      send(parent, :no_checkout)
    end)

    {:ok, owner} = Task.start fn ->
      :ok = Ownership.ownership_checkout(pool, [])
      :ok = Ownership.ownership_allow(pool, self(), pid, [])
      send parent, :checked_out
    end

    assert_receive :checked_out
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, _, _, _}

    :ok = Ownership.ownership_checkout(pool, [])

    send(pid, :refute_checkout)
    assert_receive :no_checkout
  end

  test "owner's checkin automatically revokes allowed access" do
    {:ok, pool} = start_pool()
    parent = self()

    Task.start_link fn ->
      :ok = Ownership.ownership_checkout(pool, [])
      :ok = Ownership.ownership_allow(pool, self(), parent, [])
      :ok = Ownership.ownership_checkin(pool, [])
      send parent, :checkin
      :timer.sleep(:infinity)
    end

    assert_receive :checkin
    refute_checked_out pool
  end

  test "uses ETS when the pool is named (with pid access)" do
    {:ok, pool} = start_pool(name: :ownership_pid_access)
    parent = self()

    :ok = Ownership.ownership_checkout(pool, [])
    assert_checked_out pool

    task = Task.async fn ->
      :ok = Ownership.ownership_allow(pool, parent, self(), [])
      assert_checked_out pool
      send parent, :allowed
      assert_receive :checked_in
      refute_checked_out pool
    end

    assert_receive :allowed
    :ok = Ownership.ownership_checkin(pool, [])
    send task.pid, :checked_in
    Task.await(task)
  end

  test "uses ETS when the pool is named (with named access)" do
    start_pool(name: :ownership_name_access)
    pool = :ownership_name_access
    parent = self()

    :ok = Ownership.ownership_checkout(pool, [])
    assert_checked_out pool

    task = Task.async fn ->
      :ok = Ownership.ownership_allow(pool, parent, self(), [])
      assert_checked_out pool
      send parent, :allowed
      assert_receive :checked_in
      refute_checked_out pool
    end

    assert_receive :allowed
    :ok = Ownership.ownership_checkin(pool, [])
    refute_checked_out pool

    send task.pid, :checked_in
    Task.await(task)
  end

  defp start_pool(opts \\ []) do
    stack = [{:ok, :state}]
    {:ok, agent} = A.start_link(stack)

    opts = [agent: agent, parent: self(), ownership_mode: :manual] ++ opts
    P.start_link(opts)
  end

  defp assert_checked_out(pool) do
     assert P.run(pool, fn _ -> :ok end)
   end

  defp refute_checked_out(pool) do
    assert_raise RuntimeError, ~r/cannot find ownership process/, fn ->
      P.run(pool, fn _ -> :ok end)
    end
  end
end
