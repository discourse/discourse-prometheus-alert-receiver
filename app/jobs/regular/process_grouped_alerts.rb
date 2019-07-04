# frozen_string_literal: true

module Jobs
  class ProcessGroupedAlerts < Jobs::Base
    sidekiq_options retry: false

    include AlertPostMixin

    STALE_DURATION = 5.freeze

    def execute(args)
      token = args[:token]
      data = JSON.parse(args[:data])
      graph_url = args[:graph_url]

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      if data[0]&.key?("blocks")
        # Data from {{alertmanager}}/api/v1/alerts/grouped (removed in alertmanager v0.16.0)
        current_alerts = current_alerts(data)
      else
        # Data from {{alertmanager}}/api/v1/alerts
        current_alerts = data
      end

      mark_stale_alerts(receiver, current_alerts, graph_url)
      process_silenced_alerts(receiver, current_alerts)
    end

    private

    def alert_history_key
      DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
    end

    def current_alerts(data)
      @current_alerts ||= begin
        alerts = []

        data.each do |group|
          group["blocks"].each do |block|
            alerts.concat(block["alerts"])
          end
        end

        alerts
      end
    end

    def mark_stale_alerts(receiver, current_alerts, graph_url)
      Topic.firing_alerts.each do |topic|
        DistributedMutex.synchronize("prom_alert_receiver_topic_#{topic.id}") do
          alerts = topic.custom_fields.dig(alert_history_key, 'alerts')
          updated = false

          alerts&.each do |alert|
            if alert['graph_url'].include?(graph_url) && is_firing?(alert['status'])
              is_stale = !current_alerts.any? do |current_alert|
                current_alert['labels']['id'] == alert['id']
              end

              if is_stale &&
                STALE_DURATION.minute.ago > DateTime.parse(alert["starts_at"])

                alert["status"] = "stale"
                updated = true
              end
            end
          end

          if updated
            topic.save_custom_fields(true)
            klass = DiscoursePrometheusAlertReceiver

            if base_title = topic.custom_fields[klass::TOPIC_BASE_TITLE_CUSTOM_FIELD]
              title = generate_title(base_title, alerts)
            else
              title = topic.custom_fields[klass::TOPIC_TITLE_CUSTOM_FIELD] || ''
            end

            raw = first_post_body(
              receiver: receiver,
              topic_body: topic.custom_fields[klass::TOPIC_BODY_CUSTOM_FIELD] || '',
              alert_history: alerts,
              prev_topic_id: topic.custom_fields[klass::PREVIOUS_TOPIC_CUSTOM_FIELD]
            )

            revise_topic(
              topic: topic,
              title: title,
              raw: raw,
              datacenters: datacenters(alerts),
              firing: alerts.any? { |alert| is_firing?(alert["status"]) }
            )

            publish_alert_counts
          end
        end
      end
    end

    def process_silenced_alerts(receiver, current_alerts)
      grouped_alerts = current_alerts.group_by { |a| a["labels"]["alertname"] }

      grouped_alerts.each do |alertname, active_alerts|
        topic = Topic.find_by(id: receiver[:topic_map][alertname])

        if topic
          DistributedMutex.synchronize("prom_alert_receiver_topic_#{topic.id}") do
            annotations = active_alerts.first["annotations"]

            stored_alerts = begin
              topic.custom_fields[alert_history_key]&.dig('alerts') || []
            end

            silenced = silence_alerts(stored_alerts, active_alerts,
              datacenter: active_alerts[0]["labels"]["datacenter"]
            )

            if silenced
              topic.save_custom_fields(true)

              raw = first_post_body(
                receiver: receiver,
                topic_body: annotations["topic_body"],
                alert_history: stored_alerts,
                prev_topic_id: topic.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD]
              )

              revise_topic(
                topic: topic,
                title: generate_title(annotations["topic_title"], stored_alerts),
                raw: raw,
                datacenters: datacenters(stored_alerts),
                firing: stored_alerts.any? { |alert| is_firing?(alert["status"]) }
              )

              publish_alert_counts
            end
          end
        end
      end
    end

    def silence_alerts(stored_alerts, active_alerts, datacenter:)
      silenced = false

      stored_alerts.each do |alert|
        active = active_alerts.find do |active_alert|
          active_alert["labels"]["id"] == alert["id"] &&
            alert['datacenter'] == datacenter &&
            Date.parse(active_alert["startsAt"]).to_s == Date.parse(alert["starts_at"]).to_s &&
            active_alert["status"]["state"] == "suppressed"
        end

        if active
          alert["description"] = active.dig("annotations", "description")
          state = active["status"]["state"]

          if alert["status"] != state
            alert["status"] = state
            silenced ||= true
          end
        end
      end

      silenced
    end

    def publish_alert_counts
      MessageBus.publish("/alert-receiver",
        firing_alerts_count: Topic.firing_alerts.count,
        open_alerts_count: Topic.open_alerts.count
      )
    end
  end
end
