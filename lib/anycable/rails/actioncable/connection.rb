# frozen_string_literal: true

require "action_cable/connection"
require "anycable/rails/refinements/subscriptions"
require "anycable/rails/actioncable/channel"

module ActionCable
  module Connection
    # rubocop: disable Metrics/ClassLength
    class Base # :nodoc:
      # We store logger tags in identifiers to be able
      # to re-use them in the subsequent calls
      LOG_TAGS_IDENTIFIER = "__ltags__"

      using AnyCable::Refinements::Subscriptions

      attr_reader :socket

      class << self
        def call(socket, **options)
          new(socket, options)
        end

        def identified_by(*identifiers)
          super
          Array(identifiers).each do |identifier|
            define_method(identifier) do
              instance_variable_get(:"@#{identifier}") || fetch_identifier(identifier)
            end
          end
        end
      end

      def initialize(socket, identifiers: "{}", subscriptions: [])
        @ids = ActiveSupport::JSON.decode(identifiers)

        @ltags = ids.delete(LOG_TAGS_IDENTIFIER)

        @cached_ids = {}
        @env = socket.env
        @coder = ActiveSupport::JSON
        @socket = socket
        @subscriptions = ActionCable::Connection::Subscriptions.new(self)

        # Initialize channels if any
        subscriptions.each { |id| @subscriptions.fetch(id) }
      end

      def handle_open
        logger.info started_request_message if access_logs?

        verify_origin!

        connect if respond_to?(:connect)
        send_welcome_message
      rescue ActionCable::Connection::Authorization::UnauthorizedError
        reject_request
      end

      def handle_close
        logger.info finished_request_message if access_logs?

        subscriptions.unsubscribe_from_all
        disconnect if respond_to?(:disconnect)
        true
      end

      # rubocop:disable Metrics/MethodLength
      def handle_channel_command(identifier, command, data)
        channel = subscriptions.fetch(identifier)
        case command
        when "subscribe"
          channel.handle_subscribe
          !channel.subscription_rejected?
        when "unsubscribe"
          subscriptions.remove_subscription(channel)
          true
        when "message"
          channel.perform_action ActiveSupport::JSON.decode(data)
          true
        else
          false
        end
      end
      # rubocop:enable Metrics/MethodLength

      def close
        socket.close
      end

      def transmit(cable_message)
        socket.transmit encode(cable_message)
      end

      # Generate identifiers info.
      # Converts GlobalID compatible vars to corresponding global IDs params.
      def identifiers_hash
        obj = { LOG_TAGS_IDENTIFIER => fetch_ltags }

        identifiers.each_with_object(obj) do |id, acc|
          obj = instance_variable_get("@#{id}")
          next unless obj

          acc[id] = obj.try(:to_gid_param) || obj
        end.compact
      end

      def identifiers_json
        identifiers_hash.to_json
      end

      # Fetch identifier and deserialize if neccessary
      def fetch_identifier(name)
        @cached_ids[name] ||= @cached_ids.fetch(name) do
          val = ids[name.to_s]
          next val unless val.is_a?(String)

          GlobalID::Locator.locate(val) || val
        end
      end

      def logger
        @logger ||= TaggedLoggerProxy.new(AnyCable.logger, tags: ltags || [])
      end

      private

      attr_reader :ids, :ltags

      def started_request_message
        format(
          'Started "%s"%s for %s at %s',
          request.filtered_path, " [AnyCable]", request.ip, Time.now.to_s
        )
      end

      def finished_request_message(reason = "Closed")
        format(
          'Finished "%s"%s for %s at %s (%s)',
          request.filtered_path, " [AnyCable]", request.ip, Time.now.to_s, reason
        )
      end

      def access_logs?
        AnyCable.config.access_logs_disabled == false
      end

      def fetch_ltags
        if instance_variable_defined?(:@logger)
          logger.tags
        else
          ltags
        end
      end

      def server
        ActionCable.server
      end

      def verify_origin!
        return unless socket.env.key?("HTTP_ORIGIN")

        return if allow_request_origin?

        raise(
          ActionCable::Connection::Authorization::UnauthorizedError,
          "Origin is not allowed"
        )
      end

      def reject_request
        logger.info finished_request_message("Rejected") if access_logs?
        close
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
