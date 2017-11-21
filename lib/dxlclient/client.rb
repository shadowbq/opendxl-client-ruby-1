require 'mqtt'
require 'mqtt/client'

require 'dxlclient/callback_manager'
require 'dxlclient/connection_manager'
require 'dxlclient/dxl_error'
require 'dxlclient/message/event'
require 'dxlclient/message/request'
require 'dxlclient/message/response'
require 'dxlclient/message_encoder'
require 'dxlclient/mqtt_client'
require 'dxlclient/request_manager'
require 'dxlclient/service_manager'
require 'dxlclient/uuid_generator'

# Module under which all of the DXL client functionality resides.
module DXLClient
  # rubocop:disable ClassLength

  # Class responsible for all communication with the Data Exchange Layer (DXL)
  # fabric (it can be thought of as the "main" class).
  class Client
    REPLY_TO_PREFIX = '/mcafee/client/'.freeze
    DEFAULT_REQUEST_TIMEOUT = 60 * 60
    MQTT_QOS = 0

    private_constant :REPLY_TO_PREFIX, :DEFAULT_REQUEST_TIMEOUT, :MQTT_QOS

    # rubocop: disable AbcSize, MethodLength

    # @param config [DXLClient::Config]
    def initialize(config, &block)
      @logger = DXLClient::Logger.logger(self.class.name)

      @reply_to_topic = "#{REPLY_TO_PREFIX}#{config.client_id}"

      @subscriptions = Set.new
      @subscription_lock = Mutex.new

      @mqtt_client = MQTTClient.new(config)
      @connection_manager = ConnectionManager.new(config, @mqtt_client)
      @callback_manager = create_callback_manager(config)
      @request_manager = RequestManager.new(self, @reply_to_topic)
      @service_manager = ServiceManager.new(self)

      initialize_mqtt_client
      handle_initialization_block(block)
    end

    # rubocop: enable AbcSize, MethodLength

    # Connect to a broker
    def connect
      @connection_manager.connect
    end

    def connected?
      @mqtt_client.connected?
    end

    # @return [DXLClient::Broker]
    def current_broker
      @connection_manager.current_broker
    end

    def disconnect
      @connection_manager.disconnect
    end

    def register_service_sync(service_reg_info, timeout)
      @service_manager.add_service_sync(service_reg_info, timeout)
    end

    def register_service_async(service_reg_info)
      @service_manager.add_service_async(service_reg_info)
    end

    def unregister_service_sync(service_reg_info, timeout)
      @service_manager.remove_service_sync(service_reg_info, timeout)
    end

    def unregister_service_async(service_reg_info)
      @service_manager.remove_service_async(service_reg_info)
    end

    def send_event(event)
      publish_message(event.destination_topic,
                      MessageEncoder.new.to_bytes(event))
    end

    def send_request(request)
      @logger.debugf('Sending request. Topic: %s. Id: %s.',
                     request.destination_topic, request.message_id)
      request.reply_to_topic = @reply_to_topic
      publish_message(request.destination_topic,
                      MessageEncoder.new.to_bytes(request))
    end

    def send_response(response)
      publish_message(response.destination_topic,
                      MessageEncoder.new.to_bytes(response))
    end

    def subscriptions
      @subscription_lock.synchronize do
        @subscriptions.clone
      end
    end

    def subscribe(topics)
      @subscription_lock.synchronize do
        subscriptions = topics_for_mqtt_client(topics)
        @logger.debug("Subscribing to topics: #{subscriptions}.")

        @mqtt_client.subscribe(subscriptions) if @mqtt_client.connected?

        if subscriptions.is_a?(String)
          @subscriptions.add(subscriptions)
        else
          @subscriptions.merge(subscriptions)
        end
      end
    end

    def unsubscribe(topics)
      @subscription_lock.synchronize do
        subscriptions = topics_for_mqtt_client(topics)
        @logger.debug("Unsubscribing from topics: #{subscriptions}.")

        @mqtt_client.unsubscribe(subscriptions) if @mqtt_client.connected?

        if subscriptions.respond_to?(:each)
          @subscriptions.subtract(subscriptions)
        else
          @subscriptions.delete(subscriptions)
        end
      end
    end

    def async_request(request, response_callback = nil, &block)
      if response_callback && block_given?
        raise ArgumentError,
              'Only a callback or block (but not both) may be specified'
      end
      callback = block_given? ? block : response_callback
      @request_manager.async_request(request, callback)
    end

    def sync_request(request, timeout = DEFAULT_REQUEST_TIMEOUT)
      @request_manager.sync_request(request, timeout)
    end

    def add_event_callback(topic, event_callback, subscribe_to_topic = true)
      @callback_manager.add_callback(DXLClient::Message::Event, topic,
                                     event_callback,
                                     subscribe_to_topic)
    end

    def remove_event_callback(topic, event_callback)
      @callback_manager.remove_callback(DXLClient::Message::Event, topic,
                                        event_callback)
    end

    def add_request_callback(topic, request_callback)
      @callback_manager.add_callback(DXLClient::Message::Request, topic,
                                     request_callback)
    end

    def remove_request_callback(topic, request_callback)
      @callback_manager.remove_callback(DXLClient::Message::Request, topic,
                                        request_callback)
    end

    def add_response_callback(topic, response_callback)
      @callback_manager.add_callback(DXLClient::Message::Response, topic,
                                     response_callback)
    end

    def remove_response_callback(topic, response_callback)
      @callback_manager.remove_callback(DXLClient::Message::Response, topic,
                                        response_callback)
    end

    def destroy
      @service_manager.destroy
      @request_manager.destroy
      @callback_manager.destroy
      @connection_manager.destroy
    rescue MQTT::NotConnectedException
      @logger.debug(
        'Unable to complete cleanup since MQTT client not connected'
      )
    end

    private

    def create_callback_manager(config)
      CallbackManager.new(
        self,
        config.incoming_message_queue_size,
        config.incoming_message_thread_pool_size
      )
    end

    def handle_initialization_block(block)
      return unless block
      begin
        block.call(self)
      ensure
        destroy
      end
    end

    def initialize_mqtt_client
      @connection_manager.add_connect_callback(method(:on_connect))
      @connection_manager.add_connect_callback(
        @service_manager.method(:on_connect)
      )
      @mqtt_client.add_publish_callback(method(:on_message))
    end

    def topics_for_mqtt_client(topics)
      raise ArgumentError, 'topics cannot be a Hash' if topics.is_a?(Hash)
      if topics.respond_to?(:each)
        [*topics]
      elsif topics.is_a?(String)
        topics
      else
        raise ArgumentError,
              "Unsupported data type for topics: #{topics.name}"
      end
    end

    def on_connect
      @subscription_lock.synchronize do
        unless @subscriptions.empty?
          topics = [*@subscriptions]
          @logger.debug("Resubscribing to topics: #{topics}.")
          @mqtt_client.subscribe(topics)
        end
      end
    end

    def on_message(raw_message)
      message = MessageEncoder.new.from_bytes(raw_message.payload)
      message.destination_topic = raw_message.topic
      @callback_manager.on_message(message)
    end

    def publish_message(topic, payload)
      @mqtt_client.publish(topic, payload, false, MQTT_QOS)
    end
  end
end
