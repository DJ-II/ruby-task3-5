require 'sinatra'
require 'json'
require_relative 'lib/market_data'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', '4567').to_i
set :server, :puma
set :public_folder, File.expand_path('public', __dir__)
set :views, File.expand_path('views', __dir__)
set :host_authorization, { permitted_hosts: [] }

MARKET = MarketData.new

get '/' do
  erb :index
end

get '/health' do
  content_type 'text/plain'
  'ok'
end

get '/api/search' do
  content_type :json
  JSON.generate({ results: MARKET.search(params['q']) })
rescue MarketData::InvalidParameter => e
  status 422
  JSON.generate({ error: e.message })
rescue MarketData::UpstreamError => e
  status 502
  JSON.generate({ error: e.message })
end

get '/api/history' do
  content_type :json
  JSON.generate(MARKET.history(params['symbol'], params.fetch('range', '1d')))
rescue MarketData::InvalidParameter => e
  status 422
  JSON.generate({ error: e.message })
rescue MarketData::UpstreamError => e
  status 502
  JSON.generate({ error: e.message })
end