defmodule FxcmAlchemy.RealizedPnLTest do
  @moduledoc """
  FXCM states realized P&L on the report that closes a position.

  `9052` is the gross figure and `9053` the commission taken on the same
  close, so the two together are what the account actually moved by. The
  prices the session saw answer only when the venue states neither.
  """

  use ExUnit.Case, async: true

  alias FxcmAlchemy.Portfolio

  @closed %{side: :buy, size: "1000", avg_price: "1.0800"}

  test "the stated figure is taken over what the prices imply" do
    msg = %{fxcm_pos_close_pnl: "42.75", last_px: "1.0850"}

    assert_in_delta Portfolio.realized_pnl(@closed, msg, %{}), 42.75, 1.0e-9
  end

  test "commission on the close comes out of the stated figure" do
    msg = %{fxcm_pos_close_pnl: "42.75", fxcm_pos_commission: "0.75"}

    assert_in_delta Portfolio.realized_pnl(@closed, msg, %{}), 42.0, 1.0e-9
  end

  test "a stated loss stays a loss once commission is taken" do
    msg = %{fxcm_pos_close_pnl: "-12.00", fxcm_pos_commission: "0.50"}

    assert_in_delta Portfolio.realized_pnl(@closed, msg, %{}), -12.5, 1.0e-9
  end

  test "a stated figure of zero is a figure, not an absence" do
    msg = %{fxcm_pos_close_pnl: "0.00", last_px: "1.0850"}

    assert_in_delta Portfolio.realized_pnl(@closed, msg, %{}), 0.0, 1.0e-9
  end

  test "the prices answer when the venue states nothing" do
    assert_in_delta Portfolio.realized_pnl(@closed, %{last_px: "1.0850"}, %{}), 5.0, 1.0e-9
  end

  test "an unparseable figure falls back to the prices rather than reading as zero" do
    msg = %{fxcm_pos_close_pnl: "", last_px: "1.0850"}

    assert_in_delta Portfolio.realized_pnl(@closed, msg, %{}), 5.0, 1.0e-9
  end
end
