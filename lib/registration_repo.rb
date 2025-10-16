# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'securerandom'

module Lib
  # RegistrationRepo persists conference registrations in DynamoDB.
  # Table schema:
  #   TableName: registrations (configurable via REGISTRATIONS_TABLE)
  #   PK: id (String, UUID)
  #   Attributes: name (String), email (String), destination (String), created_at (Number epoch seconds)
  class RegistrationRepo
    DEFAULT_TABLE = ENV.fetch('REGISTRATIONS_TABLE', 'registrations')

    def initialize(client: Aws::DynamoDB::Client.new, table: DEFAULT_TABLE)
      @ddb = client
      @table = table
    end

    def create(name:, email:, destination:)
      id = SecureRandom.uuid
      ts = Time.now.to_i
      item = {
        'id' => id,
        'name' => name,
        'email' => email,
        'destination' => destination,
        'created_at' => ts
      }
      @ddb.put_item(table_name: @table, item: item)
      item
    end

    def list(limit: 10)
      resp = @ddb.scan(
        table_name: @table,
        projection_expression: '#id, #n, email, destination, created_at',
        expression_attribute_names: { '#id' => 'id', '#n' => 'name' }
      )
      items = (resp.items || []).sort_by { |i| -i['created_at'].to_i }
      items.first(limit)
    rescue Aws::DynamoDB::Errors::ServiceError => e
      warn "[RegistrationRepo] list error: #{e.class}: #{e.message}"
      []
    end

    # Option B: scan-based lookup for email (sufficient for small scale; replace with GSI for production)
    def find_by_email(email)
      return nil if email.nil? || email.empty?

      last_evaluated_key = nil
      loop do
        resp = @ddb.scan(
          table_name: @table,
          filter_expression: '#e = :email',
          expression_attribute_names: { '#e' => 'email' },
          expression_attribute_values: { ':email' => email },
          exclusive_start_key: last_evaluated_key
        )
        items = resp.items || []
        match = items.find { |it| it['email'] == email }
        return match if match

        last_evaluated_key = resp.last_evaluated_key
        break if last_evaluated_key.nil?
      end

      nil
    rescue Aws::DynamoDB::Errors::ServiceError => e
      warn "[RegistrationRepo] find_by_email error: #{e.class}: #{e.message}"
      nil
    end
  end
end
