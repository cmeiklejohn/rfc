# encoding: utf-8
require 'sinatra'

bootstrap_root = File.expand_path('bootstrap', settings.root)
use Rack::Static, urls: %w[/img], root: bootstrap_root

configure :production do
  require 'rack/cache'
  use Rack::Cache,
    verbose:     settings.development?,
    metastore:   'memcached://localhost:11211/meta',
    entitystore: 'memcached://localhost:11211/body?compress=true'
end

require 'rack/deflater'
use Rack::Deflater

require_relative 'lib/sinatra_boilerplate'

set :sass do
  options = {
    style: settings.production? ? :compressed : :nested,
    load_paths: ['.', File.join(bootstrap_root, 'lib')]
  }
  options[:cache_location] = File.join(ENV['TMPDIR'], 'sass-cache') if ENV['TMPDIR']
  options
end

set :js_assets, %w[zepto.js app.coffee]

configure :development do
  set :logging, false
  ENV['DATABASE_URL'] ||= 'postgres://localhost/rfc'
end

require 'dm-core'

configure :development do
  DataMapper::Logger.new($stderr, :info)
end

configure do
  DataMapper.setup(:default, ENV['DATABASE_URL'])
end

require_relative 'models'

configure do
  DataMapper.finalize
  DataMapper::Model.raise_on_save_failure = true
  RfcFetcher.download_dir = File.expand_path('../tmp/xml', __FILE__)
end

helpers do
  def display_document_id doc
    doc_id = String === doc ? doc : doc.id
    if doc_id =~ /^ rfc (\d+) $/ix
      "RFC %d" % $1.to_i
    else
      doc_id
    end
  end

  def display_abstract text
    text.sub(/\[STANDARDS[ -]{1,2}TRA?CK\]/, '') if text
  end

  def search_path options = {}
    get_params = request.GET.merge('page' => options[:page])
    url '/search?' + Rack::Utils.build_query(get_params), false
  end

  def rfc_path doc
    doc_id = String === doc ? doc : doc.id
    url doc_id, false
  end

  # used internally in the RFC HTML generation phase
  def href_resolver
    ->(xref) { rfc_path(xref) if xref =~ /^RFC\d+$/ }
  end

  def home_path
    url '/'
  end

  def page_title title = nil
    if title
      @page_title = title
    else
      @page_title
    end
  end
end

require_relative 'lib/auto_last_modified'

before do
  page_title "Pretty RFC"
end

error 404 do
  erb :not_found
end

error do
  err = env['sinatra.error']
  locals = {}
  if err.respond_to? :message
    locals[:error_type]    = err.class.name
    locals[:error_message] = err.message
  end
  erb :error, {}, locals
end

get "/" do
  expires 5 * 60, :public
  erb :index, auto_last_modified: true
end

get "/search" do
  expires 5 * 60, :public
  @query = params[:q]
  @limit = 50
  @results = RfcDocument.search @query, page: params[:page], limit: @limit
  erb :search
end

get "/url/*" do
  rfc = RfcDocument.resolve_url(params[:splat].first, href_resolver) { not_found }
  target = url(rfc.id)
  target << '#' << params[:hash] if params[:hash]
  redirect target
end

get "/:doc_id" do
  expires 5 * 60, :public

  @rfc = RfcDocument.fetch(params[:doc_id]) { not_found }
  redirect to(@rfc.id) unless request.path == "/#{@rfc.id}"

  @rfc.make_pretty href_resolver
  erb :show, auto_last_modified: @rfc.last_modified
end
