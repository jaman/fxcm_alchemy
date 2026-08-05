# FxcmAlchemy

The FXCM adapter for the [FixAlchemy](https://hex.pm/packages/fix_alchemy) engine.

FixAlchemy runs the FIX session layer and routes messages by MsgType.
FxcmAlchemy supplies the parts FXCM does its own way: the post-logon
handshake, positions keyed by FXCMPosID, the CollateralReport account view,
FXCM's market-data and historical fields in the `9xxx` tag range, and three
sources of historical candles. Everything else — order entry, account reads,
market data subscription — comes from the engine and is re-exported here, so
`FxcmAlchemy` is the single module a caller talks to.

It also implements `FixAlchemy.Backend` as `:fxcm`, so a host managing
connections across several venues can pick it up by depending on it.

## What is FXCM-specific

- **Login.** FXCM does not consider a session usable at Logon. After `A` it
  sends UserRequest (`BE`), then CollateralInquiry (`BB`) on the UserResponse
  (`BF`), and the session is ready on the ack (`BG`). The CollateralReport
  (`BA`) is what tells the adapter its account number; positions and orders are
  requested from there.
- **Positions.** FXCM legs positions by FXCMPosID (`9041`) rather than netting
  them. A fill is only recognised as a position when it carries that tag, and
  closing one addresses the leg by id.
- **Account.** Balance, equity and margin come from the CollateralReport, not
  from a standard FIX account message.
- **Instruments.** FXCM publishes point size in FXCMSymPointSize (`9002`),
  which has no FIX 4.4 equivalent, and margin in FXCMSymMarginRatio (`9006`)
  alongside the standard `MarginRatio` (898).
- **History.** A FIX session carries no historical data of its own. FXCM
  answers a MarketDataRequest carrying FXCMTimingInterval (`9011`) and the
  FXCMStartDate/EndDate window (`9012`–`9015`) with one snapshot per candle.

## Installation

```elixir
def deps do
  [
    {:fxcm_alchemy, github: "jaman/fxcm_alchemy"}
  ]
end
```

Use `path: "../fxcm_alchemy"` instead when working on this package and its host
together; a path dependency picks up edits on the next compile, where a git one
stays pinned to the SHA in `mix.lock` until `mix deps.update fxcm_alchemy`.

`fxlite_alchemy` and `duckdbex` are optional and only needed for two of the
three historical candle sources — see [Historical candles](#historical-candles).

FXCM speaks FIX 4.4. Point the engine at a dictionary, either globally or per
connection:

```elixir
config :fix_alchemy, spec_file: "priv/specs/FIX44.xml"
```

`priv/specs/FIX44.xml` ships with this package; FXCM's own `FIXFXCM10.xml`
names the `9xxx` tags this adapter reads and is worth using if you have it.

## Quick start

A session on its own, with no host application around it:

```elixir
{:ok, conn} =
  FixAlchemy.connect(
    connection_id: "fxcm-demo",
    host: "your.fxcm.fix.host",
    port: 9443,
    username: "your_username",
    password: System.fetch_env!("FXCM_PASSWORD"),
    sender_comp_id: "your_username",
    target_comp_id: "FXCM",
    account: "01234567",
    spec_file: "priv/specs/FIX44.xml",
    defer_ready: true,
    handlers: [FxcmAlchemy.Session, FxcmAlchemy.MarketData, FxcmAlchemy.Portfolio]
  )

FxcmAlchemy.subscribe_market_data(conn, ["EUR/USD", "GBP/USD"])
FxcmAlchemy.order(conn, "EUR/USD", 1000, :buy)

FxcmAlchemy.get_positions(conn)
FxcmAlchemy.get_account_summary(conn)

FixAlchemy.disconnect(conn)
```

`defer_ready: true` and the three handlers are what make it an FXCM session
rather than a plain FIX one. A host driving it through `FixAlchemy.Backend`
sets both from `FxcmAlchemy.TradingBackend`.

This starts the session and nothing else. `FxcmAlchemy.PositionTracker`, which
marks P&L, is started per connection by the backend and not by
`FixAlchemy.connect/1` — start it yourself if you want it, as
[Positions and P&L](#positions-and-pl) describes.

## Trading

Order entry and account reads are the engine's, re-exported:

```elixir
FxcmAlchemy.order(conn, "EUR/USD", 1000, :buy)
FxcmAlchemy.limit_order(conn, "EUR/USD", 1000, :buy, 1.0850)
FxcmAlchemy.stop_order(conn, "EUR/USD", 1000, :sell, 1.0800)
FxcmAlchemy.bracket_order(conn, "EUR/USD", 1000, :buy, stop_loss: 1.0800, take_profit: 1.0900)
FxcmAlchemy.modify_order(conn, order_id, price: 1.0860)
FxcmAlchemy.cancel_order(conn, order_id)

FxcmAlchemy.get_positions(conn)
FxcmAlchemy.get_orders(conn)
FxcmAlchemy.get_collateral(conn)
FxcmAlchemy.list_instruments(conn)
```

Closing and protecting a position are FXCM's own:

```elixir
FxcmAlchemy.close_position_by_id(conn, position_id, size)
FxcmAlchemy.close_position_by_id(conn, position_id, nil)
FxcmAlchemy.close_all_for_symbol(conn, "EUR/USD")

FxcmAlchemy.attach_protection(conn, position, stop_loss: 1.0800, take_profit: 1.0900)
```

`size` may be `nil`, in which case the position's own quantity is used. A
position that came from a PositionReport closes by placing an offsetting order;
one the adapter tracked from fills closes against its `9041` leg. Any close
larger than 100,000,000 units is refused rather than sent.

## Positions and P&L

`FxcmAlchemy.PositionTracker` runs one process per trading connection, started
automatically by the backend. It holds positions and last prices, marks
unrealized P&L in the account's base currency, and publishes the result on
`"position:<connection_id>"` and `"account:<connection_id>"`.

Where the backend is not doing it for you, start it alongside the session:

```elixir
{:ok, _tracker} =
  FxcmAlchemy.PositionTracker.start_link(
    connection_id: "fxcm-demo",
    base_currency: "USD"
  )
```

It registers under the connection id, so start it once per connection and after
the session, whose portfolio process it reads the account from.

`FxcmAlchemy.PnL` does the conversion and is usable on its own:

```elixir
prices = %{"GBP/JPY" => %{bid: 190.10, ask: 190.14}, "USD/JPY" => %{bid: 150.00, ask: 150.02}}
position = %{symbol: "GBP/JPY", side: :buy, entry_price: 189.50, quantity: 1000}

FxcmAlchemy.PnL.position_pnl(position, prices, "USD")
```

A position in `XXX/YYY` accrues P&L in `YYY`. Where that is not the account
currency, the tracker converts through whichever cross the price map carries
(`ACC/YYY` or `YYY/ACC`); with neither present the position contributes `0.0`
rather than a wrong number, so subscribe to the crosses you hold.

Publishing goes through `FixAlchemy.PubSub`, the engine's contract, so this
package carries no dependency on Phoenix:

```elixir
config :fxcm_alchemy,
  pubsub_module: MyApp.PubSub,
  market_data_subscriber: MyApp.SubscriptionManager
```

`pubsub_module` names the server; with it unset the engine's own
`config :fix_alchemy, :pubsub_server` is used, and with neither set the tracker
runs and publishes nothing. `market_data_subscriber` is optional; when set, the
tracker asks it to subscribe to the symbols it needs prices for.

In a Phoenix application the default implementation forwards to
`Phoenix.PubSub` and there is nothing further to do. Elsewhere, receive the
updates by supplying an implementation:

```elixir
defmodule MyApp.FixEvents do
  @behaviour FixAlchemy.PubSub

  @impl FixAlchemy.PubSub
  def broadcast(_server, topic, message) do
    MyApp.Events.handle(topic, message)
    :ok
  end
end

config :fix_alchemy, pubsub: MyApp.FixEvents
config :fxcm_alchemy, pubsub_module: :my_app_events
```

The server name is handed to your `broadcast/3` untouched and only has to be
something other than `nil`, which is what tells the tracker anyone is listening.

## Historical candles

Pick a source per connection with the `historical_source` config field:

| Value | Source | Notes |
| --- | --- | --- |
| `fxcm_candledata` (default) | `https://candledata.fxcorporate.com` | Public weekly m1 CSVs, cached locally and aggregated with DuckDB. Published about 12 weeks behind. Needs `duckdbex`. |
| `fxcm_fxlite` | The FXCM web platform's PDAS backend | Current data. Needs `fxlite_alchemy` and platform credentials. |
| `fix_session` | The connection's own FIX session | Current data, no extra dependency. FXCM has no 4h interval, so 4h is aggregated from hourly. |
| `custom` | Your module, named in `historical_module` | Must implement `FxcmAlchemy.HistoricalCandles`. |
| `none` | — | `get_historical_candles/3` returns `{:error, :not_supported}`. |

`fxcm_fxlite` takes `fxlite_username`, `fxlite_password`, `fxlite_url`
(default `https://www.fxcorporate.com`) and `fxlite_connection` (`Demo` or
`Real`, default `Demo`). The two credential fields fall back to the FIX
`username` and `password` when left empty.

A custom source is one callback:

```elixir
defmodule MyApp.MyCandles do
  @behaviour FxcmAlchemy.HistoricalCandles

  @impl true
  def fetch_candles(symbol, opts) do
    {:ok, [%{time: 1_700_000_000, open: 1.08, high: 1.09, low: 1.07, close: 1.085}]}
  end
end
```

`opts` carries `:timeframe`, `:count`, `:before` (page further back), `:config`
(the connection's stored config map) and `:connection_id`. `time` is a Unix
timestamp in seconds.

## As a FixAlchemy backend

`FxcmAlchemy.TradingBackend` implements `FixAlchemy.Backend`, so a host that
manages connections across several venues discovers it by having
`fxcm_alchemy` as a dependency — there is nothing to register. It contributes:

- the backend id `:fxcm`, shown as "FXCM (FIX)"
- the standard connection fields (host, port, TLS, comp ids, username,
  password, account, FIX version) plus a **Historical Data** group holding
  `historical_source`, `historical_module` and the four `fxlite_*` fields
- the three handlers, deferred readiness, and FXCM's close semantics
- a `FxcmAlchemy.PositionTracker` per trading connection

The host supplies each connection's own configuration, including credentials;
this package stores none of it.

## Credentials

This package holds no credentials and none belong in it. Passwords arrive as
the `:password` connection option, or in the connection config a host passes
to the backend, and are only ever written to the wire, in the Logon and
UserRequest (`BE`) messages. Nothing here logs them.

For a standalone session, read them from the environment — `System.fetch_env!/1`
as in the quick start — or from a config file kept out of version control.

## Tests

```bash
mix test
```

The FIX session tests run against `FxcmAlchemy.FakeFixServer`, a local socket
that speaks enough of the protocol to drive the handshake. No network and no
FXCM account are needed.
