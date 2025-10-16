# frozen_string_literal: true

require 'json'
require 'rack'
require_relative './app'

# Simple Rack-to-Lambda adapter for API Gateway HTTP API (v2) events
class LambdaRackAdapter
  def initialize(app)
    @app = app
  end

  def call(event:, context: nil)
    env = event_to_env(event)
    status, headers, body = @app.call(env)

    # Normalize Set-Cookie for API Gateway HTTP API v2
    # - Prefer response cookies array (v2 format)
    # - Also include multiValueHeaders for compatibility
    cookies_array = []
    multi_value_headers = {}

    if headers
      set_cookie = headers['Set-Cookie'] || headers['set-cookie']
      if set_cookie
        cookies = set_cookie.is_a?(Array) ? set_cookie : set_cookie.to_s.split(/\r?\n/).reject(&:empty?)
        cookies_array = cookies
        headers = headers.dup
        headers.delete('Set-Cookie')
        headers.delete('set-cookie')
        multi_value_headers['Set-Cookie'] = cookies unless cookies.empty?
      end
    end

    # Adapter debug headers to observe cookie flow
    headers ||= {}
    headers = headers.dup
    headers['X-Adapter-Cookies-Array-Count'] = cookies_array.length.to_s
    headers['X-Adapter-MVH-SetCookie-Count'] = (multi_value_headers['Set-Cookie']&.length || 0).to_s
    headers['X-Adapter-Has-Cookies'] = (!cookies_array.empty?).to_s

    warn "[LambdaRackAdapter] app returned status=#{status} headers_keys=#{headers&.keys} cookies_array_count=#{cookies_array.length} multi_set_cookie_count=#{multi_value_headers['Set-Cookie']&.length}"

    response = {
      version: '2.0',
      statusCode: status,
      headers: headers,
      multiValueHeaders: multi_value_headers,
      cookies: cookies_array,
      body: collect_body(body),
      isBase64Encoded: false
    }
    # Close body if it responds to close
    body.close if body.respond_to?(:close)
    response
  rescue => e
    warn "[LambdaRackAdapter] Error: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
    {
      version: '2.0',
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: { error: 'Internal Server Error', message: 'An unexpected error occurred' }.to_json
    }
  end

  private

  def event_to_env(event)
    method = event.dig('requestContext', 'http', 'method') || event['httpMethod'] || 'GET'
    path = event.dig('requestContext', 'http', 'path') || event['path'] || '/'
    headers = (event['headers'] || {})
    query = event['rawQueryString'] || build_query(event['queryStringParameters'] || {})
    body = event['body']
    body = Base64.decode64(body) if event['isBase64Encoded']

    env = {}
    env['REQUEST_METHOD'] = method
    env['PATH_INFO'] = path
    env['QUERY_STRING'] = query.to_s
    env['rack.input'] = StringIO.new(body.to_s)
    env['rack.errors'] = $stderr
    env['rack.url_scheme'] = (headers['x-forwarded-proto'] || headers['X-Forwarded-Proto'] || 'https')
    env['SERVER_NAME'] = headers['host'] || headers['Host'] || 'lambda'
    env['SERVER_PORT'] = (env['rack.url_scheme'] == 'https') ? '443' : '80'
    env['CONTENT_TYPE'] = headers['content-type'] || headers['Content-Type'] if (headers['content-type'] || headers['Content-Type'])

    headers.each do |k, v|
      next if k.nil?
      key = 'HTTP_' + k.to_s.upcase.gsub('-', '_')
      env[key] = v
    end

    env
  end

  def build_query(params)
    return '' if params.nil? || params.empty?
    URI.encode_www_form(params)
  end

  def collect_body(rack_body)
    buf = +''
    rack_body.each { |chunk| buf << chunk }
    buf
  end
end

APP = App.new
ADAPTER = LambdaRackAdapter.new(APP)

def handler(event:, context: nil)
  ADAPTER.call(event: event, context: context)
end
