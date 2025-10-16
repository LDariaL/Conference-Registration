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
    # - Groups by local date using city's timezone offset if present (falls back to UTC)
    # - Computes min/max temps, representative description & icon, and aggregated precipitation probability (max POP per day)
    # - Skips "today" in that same local timezone and returns up to `days` next days
    def daily_from_3h_forecast(city:, days: 7, units: 'metric')
      params = { q: city, units: units, appid: @api_key }
      url = "#{OPENWEATHER_BASE}/data/2.5/forecast"
      res = HTTPX.get(url, params: params)
      raise "OpenWeather error: #{res.status} - #{res.to_s}" unless res.status == 200
      data = JSON.parse(res.to_s)
      list = Array(data['list'])

      tz_offset = (data.dig('city', 'timezone') || 0).to_i # seconds; can be negative

      # Group entries by local date string YYYY-MM-DD
      buckets = {}
      list.each do |slot|
        dt = slot['dt'].to_i
        local_date = Time.at(dt + tz_offset).utc.to_date.to_s
        temp = slot.dig('main', 'temp')
        weather0 = slot.dig('weather', 0) || {}
        desc = weather0['description']
        icon = weather0['icon']
        pop = slot['pop'] # probability of precipitation (0..1)
        buckets[local_date] ||= { temps: [], descs: [], icons: [], pops: [] }
        buckets[local_date][:temps] << temp if temp
        buckets[local_date][:descs] << desc if desc && !desc.empty?
        buckets[local_date][:icons] << icon if icon && !icon.empty?
        buckets[local_date][:pops] << pop if !pop.nil?
      end

      # Build daily summary array sorted by local date
      daily = buckets.keys.sort.map do |date|
        temps = buckets[date][:temps]
        descs = buckets[date][:descs]
        icons = buckets[date][:icons]
        pops  = buckets[date][:pops]
        rep_desc = descs.group_by { |d| d }.max_by { |_, v| v.size }&.first
        rep_icon = icons.group_by { |i| i }.max_by { |_, v| v.size }&.first
        day_pop = pops.compact.max # choose max precipitation probability in the day
        {
          'date' => date,
          'temp' => { 'min' => temps.min, 'max' => temps.max },
          'pop'  => day_pop, # 0..1
          'weather' => [{ 'description' => rep_desc, 'icon' => rep_icon }],
          'timezone_offset' => tz_offset
        }
      end

      # Skip "today" in local time
      local_today = Time.at(Time.now.to_i + tz_offset).utc.to_date.to_s
      upcoming = daily.reject { |d| d['date'] == local_today }
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
