# frozen_string_literal: true

require 'erb'
require 'openssl'
require 'base64'
require_relative './lib/weather_client'
require_relative './lib/registration_repo'

# Minimal Rack-style app for AWS Lambda/APIGW
class App
  def call(env)
    request = Rack::Request.new(env)

    warn "[App#call] #{request.request_method} #{request.path_info} query=#{request.query_string.inspect}"

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

    # Debug: log incoming params and cookies (redact email partially)
    begin
      redacted_email = email.gsub(/(.{2}).*(@.*)?/) { |m| m[0,2].to_s + '***' + ($2 || '') }
      warn "[App#index] params: destination=#{destination.inspect} name_length=#{name.length} email=#{redacted_email}"
      warn "[App#index] cookies: keys=#{req.cookies.keys}"
    rescue => e
      warn "[App#index] param logging error: #{e.class}: #{e.message}"
    end

    # Primary identity: signed cookie; Fallback: query param for first landing after redirect
    user_email = read_signed_cookie(req, 'user_email')
    user_email = req.params['user_email'].to_s if (user_email.nil? || user_email.empty?) && req.params['user_email']

    current_registration = nil
    if user_email && !user_email.empty?
      begin
        warn "[App#index] fetching current registration for user_email=#{user_email.inspect}"
        current_registration = repo.find_by_email(user_email)
        warn "[App#index] current_registration found? #{!current_registration.nil?}"

        if current_registration
          name = current_registration['name'] || name
          email = current_registration['email'] || email
          destination = current_registration['destination'] || destination
        end
      rescue => e
        warn "[App#index] find_by_email error: #{e.class}: #{e.message}"
      end
    end

    daily = nil
    error   = nil

    begin
      client  = Lib::WeatherClient.new
      warn "[App#index] fetching daily forecast (free-tier) for #{destination.inspect}"
      daily = client.daily_from_3h_forecast(city: destination, units: 'metric', days: 7)
      warn "[App#index] daily days: #{daily&.length}"
    rescue => e
      error = e.message
      warn "[App#index] weather error: #{e.class}: #{e.message}"
    end

    # Load recent registrations for the table, filter strictly to current user
    registrations = []
    begin
      warn "[App#index] loading recent registrations"
      registrations = repo.list(limit: 25)
      if user_email && !user_email.empty?
        registrations = registrations.select { |r| (r['email'] || '') == user_email }
      else
        registrations = []
      end
      warn "[App#index] registrations visible to user: #{registrations.length}"
    rescue => e
      warn "[App#index] list registrations error: #{e.class}: #{e.message}"
    end

    body = render_view('index', locals: {
      destination: destination,
      name:        name,
      email:       email,
      weather_daily: daily,
      error:       error,
      current_registration: current_registration,
      registrations: registrations
    })

    html = render_layout(content: body, flash: nil)
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

    # Debug
    begin
      red_email = email.gsub(/(.{2}).*(@.*)?/) { |m| m[0,2].to_s + '***' + ($2 || '') }
      warn "[App#register] incoming: name_length=#{name.length} email=#{red_email} destination=#{destination.inspect}"
    rescue => e
      warn "[App#register] logging error: #{e.class}: #{e.message}"
    end

    if name.empty? || email.empty? || destination.empty?
      return redirect_simple('/', user_msg: 'Please fill in all required fields.')
    end

    # Email format validation (pragmatic, case-insensitive)
    unless email =~ /\A[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\z/i
      return redirect_simple('/', user_msg: 'Please enter a valid email address.')
    end

    begin
      warn "[App#register] creating registration in DynamoDB"
      repo.create(name: name, email: email, destination: destination)
      warn "[App#register] create succeeded"

      # Set signed cookie for future visits, and pass user_email in query for immediate visibility
      path = "/?destination=#{Rack::Utils.escape_path(destination)}&user_email=#{Rack::Utils.escape_path(email)}"

      cookie_value = sign_cookie_value('user_email', email)
      user_cookie = "user_email=#{Rack::Utils.escape(cookie_value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=#{60*60*24*30}"

      headers = {
        'Location' => path,
        'Set-Cookie' => [user_cookie]
      }

      warn "[App#register] redirecting 302 to #{path} with SIGNED user_email cookie"
      [302, headers, []]
    rescue => e
      warn "[App#register] Registration error: #{e.class}: #{e.message}"
      warn e.backtrace.join("\n")
      redirect_simple('/', user_msg: "Failed to register: #{Rack::Utils.escape_html(e.message)}")
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

  # Simple redirect without flash; optional message can be encoded in destination if needed
  def redirect_simple(path, user_msg: nil)
    headers = { 'Location' => path }
    warn "[App#redirect_simple] 302 -> #{path} msg=#{user_msg.inspect}"
    [302, headers, []]
  end

  # ---------------- Cookie signing ----------------
  def signing_secret
    ENV['COOKIE_SIGNING_SECRET'] || ENV['OPENWEATHER_API_KEY'] # fallback if not provided
  end

  def sign_cookie_value(name, value)
    secret = signing_secret
    raise 'COOKIE_SIGNING_SECRET is not set' if secret.nil? || secret.empty?
    data = "#{name}=#{value}"
    mac = OpenSSL::HMAC.digest('SHA256', secret, data)
    sig = Base64.urlsafe_encode64(mac, padding: false)
    "#{value}--#{sig}"
  end

  def read_signed_cookie(req, name)
    raw = req.cookies[name]
    return nil if raw.nil? || raw.empty?
    secret = signing_secret
    return nil if secret.nil? || secret.empty?

    # format: value--base64sig
    value, sig = raw.split('--', 2)
    return nil if value.nil? || sig.nil?

    data = "#{name}=#{value}"
    mac = OpenSSL::HMAC.digest('SHA256', secret, data)
    expected = Base64.urlsafe_encode64(mac, padding: false)
    Rack::Utils.secure_compare(sig, expected) ? value : nil
  rescue => e
    warn "[App#read_signed_cookie] Invalid cookie #{name}: #{e.class}: #{e.message}"
    nil
  end
end
