# frozen_string_literal: true

require 'json'
require 'rack'
require 'lamby'
require_relative './app'

# Simple Rack-to-Lambda adapter for API Gateway HTTP API (v2) events
class LambdaRackAdapter
  def initialize(app)
    @app = app
  end

  def call(event:, context: nil)
    env = event_to_env(event)
    status, headers, body = @app.call(env)
    response = {
      statusCode: status,
      headers: headers,
      body: collect_body(body),
      isBase64Encoded: false
    }
    # Close body if it responds to close
    body.close if body.respond_to?(:close)
    response
  rescue => e
    {
      statusCode: 500,
      headers: { 'Content-Type' => 'application/json' },
      body: { error: 'Internal Server Error', message: e.message }.to_json
    }
  end

  private

  def event_to_env(event)
    method = event.dig('requestContext', 'http', 'method') || event['httpMethod']
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
    env['rack.url_scheme'] = (headers['x-forwarded-proto'] || 'https')
    env['SERVER_NAME'] = headers['host'] || 'lambda'
    env['SERVER_PORT'] = (env['rack.url_scheme'] == 'https') ? '443' : '80'
    env['CONTENT_TYPE'] = headers['content-type'] if headers['content-type']

    headers.each do |k, v|
      key = 'HTTP_' + k.upcase.gsub('-', '_')
      env[key] = v
    end

    env
  end

  def build_query(params)
    URI.encode_www_form(params)
  end

  def collect_body(rack_body)
    buf = +''
    rack_body.each { |chunk| buf << chunk }
    buf
  end
end

APP = App.new

def handler(event:, context:)
  Lamby.handler(App.new, event, context)
end
