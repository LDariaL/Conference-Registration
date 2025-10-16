# frozen_string_literal: true

require 'json'
require 'httpx'

module Lib
  # WeatherClient fetches current weather/forecast data from OpenWeather API
  # Uses the OPENWEATHER_API_KEY environment variable for authentication.
  class WeatherClient
    OPENWEATHER_BASE = 'https://api.openweathermap.org'.freeze

    def initialize(api_key: ENV['OPENWEATHER_API_KEY'])
      raise ArgumentError, 'OPENWEATHER_API_KEY is not set' if api_key.nil? || api_key.strip.empty?
      @api_key = api_key
    end

    # Build daily summaries from the free 5-day/3-hour forecast API
    # - Groups by UTC date, computes min/max temps, and representative description
    # - Skips today and returns up to `days` next days
    def daily_from_3h_forecast(city:, days: 7, units: 'metric')
      params = { q: city, units: units, appid: @api_key }
      url = "#{OPENWEATHER_BASE}/data/2.5/forecast"
      res = HTTPX.get(url, params: params)
      raise "OpenWeather error: #{res.status} - #{res.to_s}" unless res.status == 200
      data = JSON.parse(res.to_s)
      list = Array(data['list'])

      # Group entries by UTC date string YYYY-MM-DD
      buckets = {}
      list.each do |slot|
        dt = slot['dt'].to_i
        date = Time.at(dt).utc.to_date.to_s
        temp = slot.dig('main', 'temp')
        desc = slot.dig('weather', 0, 'description')
        buckets[date] ||= { temps: [], descs: [] }
        buckets[date][:temps] << temp if temp
        buckets[date][:descs] << desc if desc && !desc.empty?
      end

      # Build daily summary array sorted by date
      daily = buckets.keys.sort.map do |date|
        temps = buckets[date][:temps]
        descs = buckets[date][:descs]
        rep_desc = descs.group_by { |d| d }.max_by { |_, v| v.size }&.first
        {
          'date' => date,
          'temp' => { 'min' => temps.min, 'max' => temps.max },
          'weather' => [{ 'description' => rep_desc }]
        }
      end

      # Skip today and take next `days`
      today = Time.now.utc.to_date.to_s
      upcoming = daily.reject { |d| d['date'] == today }
      upcoming.first([days, upcoming.size].min)
    end

    # Legacy: current weather for a given city.
    def current_weather(city:, units: 'metric')
      params = { q: city, units: units, appid: @api_key }
      url = "#{OPENWEATHER_BASE}/data/2.5/weather"
      res = HTTPX.get(url, params: params)
      raise "OpenWeather error: #{res.status} - #{res.to_s}" unless res.status == 200
      JSON.parse(res.to_s)
    end

    # Legacy: 3-hour forecast limited list (kept for reference/back-compat)
    def forecast(city:, units: 'metric', limit: 5)
      params = { q: city, units: units, appid: @api_key }
      url = "#{OPENWEATHER_BASE}/data/2.5/forecast"
      res = HTTPX.get(url, params: params)
      raise "OpenWeather error: #{res.status} - #{res.to_s}" unless res.status == 200
      data = JSON.parse(res.to_s)
      list = data.fetch('list', [])
      list.first([limit, list.size].min)
    end
  end
end
