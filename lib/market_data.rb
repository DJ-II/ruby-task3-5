require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'thread'

class MarketData
  class UpstreamError < StandardError; end
  class InvalidParameter < StandardError; end

  PERIODS = {
    '1d' => { yahoo_range: '1d', yahoo_interval: '5m', twelve_interval: '5min', twelve_size: 110 },
    '5d' => { yahoo_range: '5d', yahoo_interval: '15m', twelve_interval: '15min', twelve_size: 150 },
    '1w' => { yahoo_range: '1mo', yahoo_interval: '60m', twelve_interval: '1h', twelve_size: 160 },
    '1m' => { yahoo_range: '1mo', yahoo_interval: '1d', twelve_interval: '1day', twelve_size: 35 },
    '1y' => { yahoo_range: '1y', yahoo_interval: '1d', twelve_interval: '1day', twelve_size: 290 }
  }.freeze

  POPULAR = [
    ['AAPL', 'Apple Inc.', 'NASDAQ'],
    ['MSFT', 'Microsoft Corporation', 'NASDAQ'],
    ['NVDA', 'NVIDIA Corporation', 'NASDAQ'],
    ['GOOGL', 'Alphabet Inc.', 'NASDAQ'],
    ['AMZN', 'Amazon.com Inc.', 'NASDAQ'],
    ['META', 'Meta Platforms Inc.', 'NASDAQ'],
    ['TSLA', 'Tesla Inc.', 'NASDAQ'],
    ['AMD', 'Advanced Micro Devices', 'NASDAQ'],
    ['NFLX', 'Netflix Inc.', 'NASDAQ'],
    ['INTC', 'Intel Corporation', 'NASDAQ'],
    ['ORCL', 'Oracle Corporation', 'NYSE'],
    ['IBM', 'IBM', 'NYSE'],
    ['JPM', 'JPMorgan Chase & Co.', 'NYSE'],
    ['V', 'Visa Inc.', 'NYSE'],
    ['MA', 'Mastercard Inc.', 'NYSE'],
    ['KO', 'Coca-Cola Company', 'NYSE'],
    ['DIS', 'Walt Disney Company', 'NYSE'],
    ['NKE', 'Nike Inc.', 'NYSE'],
    ['BA', 'Boeing Company', 'NYSE'],
    ['WMT', 'Walmart Inc.', 'NASDAQ'],
    ['SAP', 'SAP SE', 'NYSE'],
    ['ASML', 'ASML Holding', 'NASDAQ'],
    ['CDR.WA', 'CD Projekt', 'WSE'],
    ['PKO.WA', 'PKO Bank Polski', 'WSE'],
    ['PZU.WA', 'PZU', 'WSE']
  ].freeze

  def initialize
    @cache = {}
    @lock = Mutex.new
  end

  def search(query)
    query = query.to_s.strip[0, 50]
    raise InvalidParameter, 'Enter a company name or ticker symbol.' if query.empty?

    cached("search:#{query.downcase}", 180) do
      local = POPULAR.filter_map do |sym, name, exchange|
        if sym.downcase.include?(query.downcase) || name.downcase.include?(query.downcase)
          { symbol: sym, name: name, exchange: exchange }
        end
      end
      remote = begin
        twelve_key? ? search_twelve(query) : search_yahoo(query)
      rescue UpstreamError
        [] # The input remains usable for direct ticker lookup.
      end
      (local + remote).uniq { |item| item[:symbol] }.first(12)
    end
  end

  def history(symbol, period)
    symbol = symbol.to_s.strip.upcase
    unless symbol.match?(/\A[A-Z0-9.^=\-]{1,20}\z/)
      raise InvalidParameter, 'Invalid ticker symbol.'
    end
    raise InvalidParameter, 'Unsupported time range.' unless PERIODS.key?(period)

    cached("history:#{symbol}:#{period}", period == '1y' ? 300 : 75) do


      if twelve_key?
        begin
          history_twelve(symbol, period)
        rescue UpstreamError

          history_yahoo(symbol, period)
        end
      else
        history_yahoo(symbol, period)
      end
    end
  end

  private

  def twelve_key?
    !ENV.fetch('TWELVE_DATA_API_KEY', '').strip.empty?
  end

  def cached(key, ttl)
    previous = @lock.synchronize { @cache[key] }
    return previous[:value] if previous && previous[:expires] > Time.now.to_f

    value = yield
    @lock.synchronize do
      @cache.delete_if { |_k, v| v[:expires] <= Time.now.to_f } if @cache.size > 350
      @cache[key] = { value: value, expires: Time.now.to_f + ttl }
    end
    value
  end

  def fetch_json(host, path, params)
    uri = URI::HTTPS.build(host: host, path: path, query: URI.encode_www_form(params))
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 6
    http.read_timeout = 9
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = 'Mozilla/5.0 (compatible; StudentStockDashboard/1.0)'
    req['Accept'] = 'application/json'
    response = http.request(req)
    raise UpstreamError, "Data provider error (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError, Timeout::Error, SocketError, EOFError, Errno::ECONNRESET, IOError => e
    raise UpstreamError, "Unable to retrieve market data: #{e.class}."
  end

  def search_yahoo(query)
    data = fetch_json('query1.finance.yahoo.com', '/v1/finance/search', { q: query, quotesCount: 12, newsCount: 0 })
    Array(data['quotes']).filter_map do |q|
      next unless %w[EQUITY ETF].include?(q['quoteType'])
      symbol = q['symbol'].to_s.upcase
      next unless symbol.match?(/\A[A-Z0-9.^=\-]{1,20}\z/)

      { symbol: symbol, name: q['shortname'] || q['longname'] || symbol,
        exchange: q['exchDisp'] || q['exchange'] || '' }
    end
  end

  def search_twelve(query)
    data = fetch_json('api.twelvedata.com', '/symbol_search',
                      { symbol: query, outputsize: 15, apikey: ENV.fetch('TWELVE_DATA_API_KEY') })
    Array(data['data']).filter_map do |item|
      sym = item['symbol'].to_s.upcase
      next unless sym.match?(/\A[A-Z0-9.^=\-]{1,20}\z/)
      next unless item['instrument_type'].to_s.downcase.match?(/stock|equity|etf/) || item['instrument_type'].nil?

      { symbol: sym, name: item['instrument_name'] || sym, exchange: item['exchange'] || '' }
    end
  end

  def history_yahoo(symbol, period)
    config = PERIODS.fetch(period)
    data = fetch_json('query1.finance.yahoo.com', "/v8/finance/chart/#{symbol}",
                      { range: config[:yahoo_range], interval: config[:yahoo_interval],
                        includePrePost: 'false', events: 'history' })
    record = data.dig('chart', 'result', 0)
    raise UpstreamError, 'No market data found for this stock.' unless record

    meta = record.fetch('meta', {})
    quote = record.dig('indicators', 'quote', 0) || {}
    daily = %w[1m 1y].include?(period)
    bars = Array(record['timestamp']).each_with_index.filter_map do |seconds, index|
      close = quote.fetch('close', [])[index]
      open = quote.fetch('open', [])[index]
      high = quote.fetch('high', [])[index]
      low = quote.fetch('low', [])[index]
      next if [close, open, high, low].any?(&:nil?)

      { time: daily ? Time.at(seconds).utc.strftime('%Y-%m-%d') : seconds.to_i,
        open: open.to_f, high: high.to_f, low: low.to_f, close: close.to_f,
        volume: (quote.fetch('volume', [])[index] || 0).to_i }
    end
    bars = bars.select { |b| b[:time] >= Time.now.to_i - 7 * 86_400 } if period == '1w'
    normalize(symbol, period, bars, meta['shortName'] || meta['longName'] || symbol,
              meta['currency'] || '', meta['exchangeTimezoneName'] || 'UTC', 'Yahoo Finance',
              daily: daily)
  end

  def history_twelve(symbol, period)
    config = PERIODS.fetch(period)
    daily = %w[1m 1y].include?(period)
    data = fetch_json('api.twelvedata.com', '/time_series', {
                        symbol: symbol, interval: config[:twelve_interval],
                        outputsize: config[:twelve_size], timezone: 'UTC',
                        apikey: ENV.fetch('TWELVE_DATA_API_KEY')
                      })
    raise UpstreamError, 'No market data available from the provider.' unless data['status'] != 'error' && data['values'].is_a?(Array)

    bars = data['values'].filter_map do |v|
      raw_time = v['datetime']
      next unless raw_time && v['close'] && v['open'] && v['high'] && v['low']
      timestamp = daily ? raw_time[0, 10] : Time.parse("#{raw_time} UTC").to_i
      { time: timestamp, open: v['open'].to_f, high: v['high'].to_f,
        low: v['low'].to_f, close: v['close'].to_f, volume: v['volume'].to_i }
    end
    bars = bars.select { |b| b[:time] >= Time.now.to_i - 7 * 86_400 } if period == '1w'
    meta = data['meta'] || {}
    normalize(symbol, period, bars, meta['name'] || symbol, meta['currency'] || '',
              daily ? 'UTC' : 'UTC', 'Twelve Data', daily: daily)
  rescue ArgumentError
    raise UpstreamError, 'Invalid timestamp format in market data.'
  end

  def normalize(symbol, period, bars, name, currency, timezone, source, daily:)
    bars = bars.sort_by { |b| b[:time] }.uniq { |b| b[:time] }
    raise UpstreamError, 'No data available for this time range.' if bars.empty?

    first = bars.first[:close]
    last = bars.last[:close]
    change = last - first
    change_percent = first.zero? ? 0 : change / first * 100
    {
      symbol: symbol, name: name, currency: currency, timezone: timezone,
      period: period, daily: daily, provider: source, updated_at: Time.now.utc.iso8601,
      last_bar_time: bars.last[:time], price: last.round(6),
      change: change.round(6), change_percent: change_percent.round(3),
      volume: bars.last[:volume], bars: bars
    }
  end
end