# frozen_string_literal: true

require 'json'
require 'httpx'

module Lib
  # WeatherClient fetches current weather/forecast data from OpenWeather API
  # Uses the OPENWEATHER_API_KEY environment variable for authentication.
  class WeatherClient
    OPENWEATHER_BASE = 'https://api.openweathermap.org/data/2.5'.freeze

    def initialize(api_key: ENV['OPENWEATHER_API_KEY'])
      raise ArgumentError, 'OPENWEATHER_API_KEY is not set' if api_key.nil? || api_key.strip.empty?
      @api_key = api_key
    end

    # Fetches current weather for a given city.
    # params:
    # - city: String (e.g., 'London')
    # - units: 'metric' | 'imperial' (default 'metric')
    # returns: Hash with weather data
    def current_weather(city:, units: 'metric')
      query = {
        q: city,
        units: units,
        appid: @api_key
      }
      url = "#{OPENWEATHER_BASE}/weather"
      response = HTTPX.get(url, params: query)
      raise "OpenWeather error: #{response.status} - #{response.to_s}" unless response.status == 200
      JSON.parse(response.to_s)
    end

    # Fetches a simple 5-day/3-hour forecast and returns the next 5 time slots.
    def forecast(city:, units: 'metric', limit: 5)
      query = {
        q: city,
        units: units,
        appid: @api_key
      }
      url = "#{OPENWEATHER_BASE}/forecast"
      response = HTTPX.get(url, params: query)
      raise "OpenWeather error: #{response.status} - #{response.to_s}" unless response.status == 200
      data = JSON.parse(response.to_s)
      list = data.fetch('list', [])
      list.first([limit, list.size].min)
    end
  end
end
