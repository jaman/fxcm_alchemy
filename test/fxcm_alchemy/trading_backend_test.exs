defmodule FxcmAlchemy.TradingBackendTest do
  use ExUnit.Case, async: true

  alias FxcmAlchemy.TradingBackend

  defp names(config), do: Enum.map(TradingBackend.configured_sessions(config), & &1.name)

  describe "configured_sessions/1 with stored two-group configs" do
    test "trading fields alone configure a single trading session" do
      config = [host: "fix.example.com", port: 4017, sender_comp_id: "client1"]

      assert [session] = TradingBackend.configured_sessions(config)
      assert session.name == :trading
      assert session.sender_comp_id == "client1"
      assert session.roles == [:trading, :market_data]
    end

    test "market data fields alone configure a single md session" do
      config = [host_md: "md.example.com", port_md: 4018, sender_comp_id_md: "md_client1"]

      assert [session] = TradingBackend.configured_sessions(config)
      assert session.name == :md
      assert session.sender_comp_id == "md_client1"
      assert session.roles == [:market_data]
      assert session.overrides == [host: "md.example.com", port: 4018]
    end

    test "both field groups configure both sessions" do
      config = [
        host: "fix.example.com",
        port: 4017,
        sender_comp_id: "client1",
        host_md: "md.example.com",
        port_md: 4018,
        sender_comp_id_md: "md_client1"
      ]

      assert [trading, market_data] = TradingBackend.configured_sessions(config)
      assert trading.name == :trading
      assert trading.roles == [:trading]
      assert market_data.name == :md
      assert market_data.roles == [:market_data]
    end

    test "blank strings do not count as configured" do
      config = [
        host: "fix.example.com",
        port: 4017,
        sender_comp_id: "client1",
        host_md: "",
        port_md: "",
        sender_comp_id_md: ""
      ]

      assert names(config) == [:trading]
    end

    test "an incomplete field group does not configure a session" do
      config = [host: "fix.example.com", sender_comp_id: "client1"]

      assert TradingBackend.configured_sessions(config) == []
    end
  end

  describe "backend_config/0" do
    test "declares the session group and the FXCM historical section" do
      config = TradingBackend.backend_config()

      assert config.sessions.name == :sessions
      assert Enum.any?(config.groups, &(&1.id == :historical))

      assert Enum.any?(
               config.fields,
               &(&1.name == :historical_source and &1.group == :historical)
             )
    end

    test "keeps the historical fields out of what a session may override" do
      config = TradingBackend.backend_config()
      overridable = FixAlchemy.Backend.overridable_fields(config.fields)

      refute Enum.any?(overridable, &(&1.name == :historical_source))
      assert Enum.any?(overridable, &(&1.name == :port))
    end
  end
end
