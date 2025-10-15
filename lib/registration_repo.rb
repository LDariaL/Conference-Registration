# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'securerandom'

module Lib
  # RegistrationRepo persists conference registrations in DynamoDB.
  # Table schema (proposed):
  #   TableName: registrations
  #   PK: id (String, UUID)
  #   Attributes: name (String), email (String), destination (String), created_at (Number epoch)
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
      resp = @ddb.scan(table_name: @table, limit: limit, projection_expression: '#id, #n, email, destination, created_at',
                       expression_attribute_names: { '#id' => 'id', '#n' => 'name' })
      (resp.items || []).sort_by { |i| -i['created_at'].to_i }
    end
  end
end
