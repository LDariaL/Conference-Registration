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


    user_email = req.cookies['user_email']


    current_registration = nil
    if user_email && !user_email.empty?
      begin
        current_registration = repo.find_by_email(user_email)

        if current_registration
          name = current_registration['name'] || name
          email = current_registration['email'] || email
          destination = current_registration['destination'] || destination
        end
      rescue => e
        puts "Error loading registration: #{e.message}"
      end
    end

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
      current_registration: current_registration
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


      path = "/?destination=#{Rack::Utils.escape_path(destination)}"
      msg = 'Registration successful!'

      flash_cookie = "flash=#{Rack::Utils.escape(msg)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=5"
      user_cookie = "user_email=#{Rack::Utils.escape(email)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=#{60*60*24*30}"

      headers = {
        'Location' => path,
        'Set-Cookie' => "#{flash_cookie}\n#{user_cookie}"
      }

      [302, headers, []]
    rescue => e
      puts "Registration error: #{e.message}"
      puts e.backtrace.join("\n")
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
      'Set-Cookie'  => "flash=#{Rack::Utils.escape(msg)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=5"
    }
    [302, headers, []]
  end
end
