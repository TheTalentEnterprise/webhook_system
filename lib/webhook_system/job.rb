module WebhookSystem

  # This is the ActiveJob in charge of actually sending each event
  class Job < ActiveJob::Base

    # Exception class around non 200 responses
    class RequestFailed < RuntimeError
      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    # Represents response for an exception we get when doing Faraday http call
    class ErrorResponse
      def initialize(exception)
        @exception = exception
      end

      def status
        0 # no HTTP response status as we got an exception while trying to perform the request
      end

      def headers
        {}
      end

      def body
        [@exception.class.name, @exception.message, *@exception.backtrace].join("\n")
      end
    end

    def perform(subscription, event)
      self.class.post(subscription, event)
    end

    def self.post(subscription, event)
      client = build_client
      request = build_request(client, subscription, event)

      response =
        begin
          client.builder.build_response(client, request)
        rescue RuntimeError => exception
          ErrorResponse.new(exception)
        end

      log_response(subscription, event, request, response)
      ensure_success(response.status, :POST, subscription.url)
    end

    def self.ensure_success(status, http_method, url)
      unless (200..299).cover? status
        raise RequestFailed.new("#{http_method} request to #{url} failed with code: #{status}", status)
      end
    end

    def self.build_request(client, subscription, event)
      payload, headers = Encoder.encode(subscription.secret, event, format: format_for_subscription(subscription))
      client.build_request(:post) do |req|
        req.url subscription.url
        req.headers.merge!(headers)
        req.body = payload.to_s
      end
    end

    def self.format_for_subscription(subscription)
      subscription.encrypt ? 'base64+aes256' : 'json'
    end

    def self.log_response(subscription, event, request, response)
      event_log = EventLog.construct(subscription, event, request, response)

      # we write log in a separate thread to make sure it is created even if the whole job fails
      # Usually any background job would be wrapped into transaction,
      # so if the job fails we would rollback any DB changes, including the even log record.
      # We want the even log record to always be created, so we check if we are running inside the transaction,
      # if we are - we create the record in a separate thread. New Thread means a new DB connection and
      # ActiveRecord transactions are per connection, which gives us the "transaction jailbreak".
      if ActiveRecord::Base.connection.open_transactions == 0
        event_log.save!
      else
        Thread.new { event_log.save! }.join
      end
    end

    def self.build_client
      Faraday.new do |faraday|
        faraday.response :logger if ENV['WEBHOOK_DEBUG']
        # use Faraday::Encoding middleware
        faraday.response :encoding
        faraday.adapter Faraday.default_adapter
      end
    end
  end
end
