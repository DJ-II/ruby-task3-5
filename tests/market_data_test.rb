require 'minitest/autorun'
require_relative '../lib/market_data'

class MarketDataTest < Minitest::Test
  def setup
    @market = MarketData.new
  end

  def test_invalid_symbol
    assert_raises(MarketData::InvalidParameter) { @market.history('BAD/../../', '1d') }
  end

  def test_invalid_range
    assert_raises(MarketData::InvalidParameter) { @market.history('AAPL', '2y') }
  end

  def test_change_calculation
    bars = [
      { time: 100, open: 10.0, high: 12.0, low: 9.0, close: 10.0, volume: 8 },
      { time: 200, open: 10.0, high: 12.0, low: 9.0, close: 11.0, volume: 9 }
    ]
    result = @market.send(:normalize, 'TEST', '1d', bars, 'Test', 'USD', 'UTC', 'Fixture', daily: false)
    assert_equal(11.0, result[:price])
    assert_equal(1.0, result[:change])
    assert_equal(10.0, result[:change_percent])
    assert_equal(9, result[:volume])
  end

  def test_cache_returns_same_result
    calls = 0
    2.times do
      @market.send(:cached, 'test', 100) { calls += 1 }
    end
    assert_equal 1, calls
  end
end

class MarketDataMockTest < Minitest::Test
  def setup
    @market = MarketData.new
    @market.define_singleton_method(:fetch_json) do |_host, path, _params|
      if path.include?('/v1/finance/search')
        { 'quotes' => [{ 'quoteType' => 'EQUITY', 'symbol' => 'AAPL', 'shortname' => 'Apple Inc.', 'exchDisp' => 'NASDAQ' }] }
      else
        {
          'chart' => { 'result' => [{
            'meta' => { 'shortName' => 'Apple Inc.', 'currency' => 'USD', 'exchangeTimezoneName' => 'America/New_York' },
            'timestamp' => [1_767_000_000, 1_767_000_300],
            'indicators' => { 'quote' => [{
              'open' => [100, 105], 'high' => [106, 109], 'low' => [98, 103],
              'close' => [104, 108], 'volume' => [10_000, 12_000]
            }] }
          }], 'error' => nil }
        }
      end
    end
  end

  def test_history_from_mocked_provider
    result = @market.history('AAPL', '1d')
    assert_equal 'AAPL', result[:symbol]
    assert_equal 'Yahoo Finance', result[:provider]
    assert_equal 2, result[:bars].length
    assert_equal 108, result[:price]
    assert_equal 4, result[:change]
    assert_equal 12_000, result[:volume]
  end

  def test_search_from_mocked_provider
    result = @market.search('apple')
    assert_equal 'AAPL', result.first[:symbol]
    assert_equal 'Apple Inc.', result.first[:name]
  end
end
