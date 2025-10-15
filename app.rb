# frozen_string_literal: true

require 'erb'
require_relative './lib/weather_client'
require_relative './lib/registration_repo'

# Minimal Rack-style app for AWS Lambda/APIGW
class App
  def call(env)
    request = Rack::Request.new(env)

    case [request.request_method, request.path_info]
    when ['GET', '/']
      handle_index(request)
    when ['POST', '/register']
      handle_register(request)
    else
      [404, { 'Content-Type' => 'text/plain' }, ['Not found']]
    end
  end

  private

  def handle_index(req)
    # Default destination can be provided via query param or env
    destination = (req.params['destination'] || ENV['DEFAULT_DESTINATION'] || 'London').to_s
    name        = req.params['name'].to_s
    email       = req.params['email'].to_s
    flash       = req.cookies['flash']

    weather = nil
    error   = nil

    begin
      client  = Lib::WeatherClient.new
      weather = client.forecast(city: destination, units: 'metric', limit: 5)
    rescue => e
      error = e.message
    end

    body = render_view('index', locals: {
      destination: destination,
      name:        name,
      email:       email,
      weather:     weather,
      error:       error,
      registrations: repo.list(limit: 10)
    })

    html = render_layout(content: body, flash: flash)
    [200, { 'Content-Type' => 'text/html; charset=utf-8' }, [html]]
  end

  def handle_register(req)
    unless req.post?
      return [405, { 'Content-Type' => 'text/plain' }, ['Method Not Allowed']]
    end

    # Basic validation and sanitation
    name        = (req.params['name'] || '').strip
    email       = (req.params['email'] || '').strip
    destination = (req.params['destination'] || '').strip

    if name.empty? || email.empty? || destination.empty?
      return redirect_with_message('/', 'Please fill in all required fields.')
    end

    begin
      repo.create(name: name, email: email, destination: destination)
      redirect_with_message("/?destination=#{Rack::Utils.escape_path(destination)}",
                            'Registration successful!')
    rescue => e
      redirect_with_message('/', "Failed to register: #{Rack::Utils.escape_html(e.message)}")
    end
  end

  def repo
    @repo ||= Lib::RegistrationRepo.new
  end

  def render_view(name, locals: {})
    template = File.read(File.join(__dir__, 'views', "#{name}.erb"))
    ERB.new(template).result_with_hash(locals)
  end

  def render_layout(content:, flash: nil)
    template = File.read(File.join(__dir__, 'views', 'layout.erb'))
    ERB.new(template).result_with_hash(content: content, flash: flash)
  end

  def redirect_with_message(path, msg)
    headers = {
      'Location'    => path,
      'Set-Cookie'  => "flash=#{Rack::Utils.escape(msg)}; Path=/; HttpOnly; SameSite=Lax"
    }
    [302, headers, []]
  end
end
