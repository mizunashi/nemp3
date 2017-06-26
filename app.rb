# frozen_string_literal: true

require 'aws-sdk'
require 'date'
require 'digest'
require 'json'
require 'net/http'
require 'rqrcode'
require 'sinatra'

helpers do
  include Rack::Utils
  alias_method :h, :escape_html
end

set :root, File.dirname(__FILE__)
set :price, 40

if settings.production?
  set :payment_address, 'NBCR2G-JL7VJF-3FKVI6-6SMZCG-4YBC6H-3BM2A6-LLTM'
  set :nodes, [
    '85.25.36.97:7890',
    '108.61.182.27:7890',
    '108.61.168.86:7890',
    '104.238.161.61:7890',
    '88.99.192.82:7890'
  ]
else
  set :payment_address, 'TCQFU2-U2UR27-EYLADA-6FNE6K-Y7ONFM-7YH7ZY-REBS'
  set :nodes, [
    '37.187.70.29:7890',
    '104.128.226.60:7890',
    '23.228.67.85:7890',
    '50.3.87.123:7890',
    '192.3.61.243:7890',
    '150.95.145.157:7890'
  ]
end

get '/' do
  xem_price_btc = Net::HTTP.get_response(
    URI('https://bittrex.com/api/v1.1/public/getticker?market=btc-xem')
  )
  @xem_price_satoshis =
    if xem_price_btc.is_a? Net::HTTPSuccess
      (JSON.parse(xem_price_btc.body)['result']['Last'] * 10**8).to_i
    else
      7000
    end

  xbt_price_usd = Net::HTTP.get_response(
    URI('https://api.kraken.com/0/public/Ticker?pair=XXBTZUSD')
  )
  @xbt_price_last =
    if xbt_price_usd.is_a? Net::HTTPSuccess
      JSON.parse(xbt_price_usd.body)['result']['XXBTZUSD']['c'][0].to_f
    else
      2200.00
    end

  @xem_price_usd = (@xbt_price_last * 10**-8) * @xem_price_satoshis

  erb :index
end

post '/' do
  @xem_price_usd = params[:xem_price_usd].to_f
  @usd_price = @xem_price_usd * settings.price

  # Truncate the hash for cheaper tx fee.
  @id_hash = Digest::SHA256.hexdigest(params[:user_email] +
  ENV['NEMP3_SECRET'])[0, 31]
  payment_data = {
    v: 2,
    type: 2,
    data: {
      addr: settings.payment_address.delete('-'),
      amount: settings.price * 10**6,
      msg: @id_hash
    }
  }

  qrcode = RQRCode::QRCode.new(payment_data.to_json)
  @qr = qrcode.as_svg(
    offset: 0,
    color: '000',
    shape_rendering: 'crispEdges',
    module_size: 4
  )

  erb :payment
end

post '/download' do
  node = ''
  @node_name = ''

  settings.nodes.each do |node_address|
    begin
      node_info = Net::HTTP.get_response(
        URI("http://#{node_address}/node/info")
      )
      if node_info.is_a? Net::HTTPSuccess
        node = node_address
        @node_name = JSON.parse(node_info.body)['identity']['name']
        break
      else
        next
      end
    rescue
      next
    end
  end

  # Search for txs in groups of 25
  parameters = ''
  data = []
  loop do
    transfers = Net::HTTP.get(
      URI("http://#{node}/account/transfers/incoming?address="\
      "#{settings.payment_address.delete('-')}#{parameters}")
    )
    latest_data = JSON.parse(transfers)['data']
    break if latest_data.empty?
    tx_hash = latest_data.last['meta']['hash']['data']
    tx_id = latest_data.last['meta']['id']
    parameters = "&hash=#{tx_hash}&id=#{tx_id}"
    data.concat latest_data
  end

  @id_hash = params[:id_hash]
  @encoded_message = @id_hash.unpack('H*')
  @search = data.find_all do |tx|
    tx['transaction']['message']['payload'] == @encoded_message[0]
  end
  @tx_list = []
  @paid = []
  @transaction = @search.count > 1 ? 'transactions' : 'transaction'

  if @search.empty?
    erb :tx_not_found
  else
    @search.each_with_index do |tx, index|
      @tx_list[index] = tx['meta']['hash']['data']
      @paid << tx['transaction']['amount']
    end
    @paid = @paid.sum.to_f * 10**-6
    @difference = settings.price - @paid
    if @paid < settings.price
      erb :low_payment
    else
      @download_link = Digest::SHA256.hexdigest(DateTime.now.strftime('%s'))
      erb :download
    end
  end
end

post '/:download_link' do
  signer = Aws::S3::Presigner.new
  url =
  if settings.production?
    signer.presigned_url(
      :get_object,
      bucket: 'nemp3',
      key: 'Ochre - Beyond the Outer Loop.zip',
      expires_in: 300
    )
  else
    signer.presigned_url(
      :get_object,
      bucket: 'nemp3',
      key: 'Empty.zip',
      expires_in: 300
    )
  end
  redirect url
end

not_found do
  erb :'404'
end
