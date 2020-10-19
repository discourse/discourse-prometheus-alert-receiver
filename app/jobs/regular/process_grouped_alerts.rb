# frozen_string_literal: true

module Jobs
  class ProcessGroupedAlerts < ::Jobs::Base
    sidekiq_options retry: false

    include AlertPostMixin

    # Processes data from {{alertmanager}}/api/v1/alerts
    # Sent by discourse/prometheus-alertmanager-webhooks
    def execute(args)
      token = args[:token]
      data = JSON.parse(args[:data])

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      external_url = args.symbolize_keys[:external_url]

      parsed_alerts = parse_alerts(data, external_url: external_url)

      update_open_alerts(receiver, parsed_alerts, external_url: external_url)
    end

    private

    def update_open_alerts(receiver, parsed_alerts, external_url:)
      parsed_alerts.each { |a| a[:topic_id] = receiver[:topic_map][a[:alertname]] }
        .reject! { |a| a[:topic_id].nil? }

      updated_topic_ids = AlertReceiverAlert.update_alerts(parsed_alerts, mark_stale_external_url: external_url)

      return if updated_topic_ids.blank?

      Topic.where(id: updated_topic_ids).each do |topic|
        DistributedMutex.synchronize("prom_alert_receiver_topic_#{topic.id}") do
          alertname = receiver["topic_map"].key(topic.id)
          revise_topic(topic: topic) if alertname
        end
      end

      publish_alert_counts
    end

  end
end
