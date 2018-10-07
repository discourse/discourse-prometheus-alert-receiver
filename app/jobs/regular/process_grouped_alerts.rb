module Jobs
  class ProcessGroupedAlerts < Jobs::Base
    include AlertPostMixin

    STALE_DURATION = 5.freeze

    def execute(args)
      token = args[:token]
      data = JSON.parse(args[:data])
      external_url = args[:external_url]
      graph_url = args[:graph_url]

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      mark_stale_alerts(receiver, data, external_url, graph_url)
      process_silenced_alerts(receiver, data, external_url)
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

    def mark_stale_alerts(receiver, data, external_url, graph_url)
      Topic.firing_alerts.each do |topic|
        alerts = topic.custom_fields.dig(alert_history_key, 'alerts')
        updated = false

        alerts.each do |alert|
          if alert['graph_url'].include?(graph_url) && is_firing?(alert['status'])
            is_stale = !current_alerts(data).any? do |current_alert|
              current_alert['labels']['id'] == alert['id'] &&
                DateTime.parse(current_alert['startsAt']).to_s == DateTime.parse(alert['starts_at']).to_s
            end

            if is_stale &&
               STALE_DURATION.minute.since > DateTime.parse(alert["starts_at"])

              alert["status"] = "stale"
              updated = true
            end
          end
        end

        if updated
          topic.save_custom_fields(true)
          klass = DiscoursePrometheusAlertReceiver

          raw = first_post_body(
            receiver: receiver,
            external_url: external_url,
            topic_body: topic.custom_fields[klass::TOPIC_BODY_CUSTOM_FIELD] || '',
            alert_history: alerts,
            prev_topic_id: topic.custom_fields[klass::PREVIOUS_TOPIC_CUSTOM_FIELD]
          )

          title = topic_title(
            alert_history: alerts,
            datacenter: topic.custom_fields[klass::DATACENTER_CUSTOM_FIELD] || '',
            topic_title: topic.custom_fields[klass::TOPIC_TITLE_CUSTOM_FIELD] || '',
            created_at: topic.created_at
          )

          revise_topic(topic, title, raw)
          publish_alert_counts
        end
      end
    end

    def process_silenced_alerts(receiver, data, external_url)
      data.each do |group|
        group_key = group["groupKey"]
        topic = Topic.find_by(id: receiver[:topic_map][group_key])

        if topic
          group["blocks"].each do |block|
            active_alerts = block["alerts"]
            annotations = active_alerts.first["annotations"]

            stored_alerts = begin
              topic.custom_fields[alert_history_key]&.dig('alerts') || []
            end

            silence_alerts(stored_alerts, active_alerts)
            topic.save_custom_fields(true)

            raw = first_post_body(
              receiver: receiver,
              external_url: external_url,
              topic_body: annotations["topic_body"],
              alert_history: stored_alerts,
              prev_topic_id: topic.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD]
            )

            title = topic_title(
              alert_history: stored_alerts,
              datacenter: group["labels"]["datacenter"],
              topic_title: annotations["topic_title"],
              created_at: topic.created_at
            )

            revise_topic(topic, title, raw)
            publish_alert_counts
          end
        end
      end
    end

    def silence_alerts(stored_alerts, active_alerts)
      stored_alerts.each do |alert|
        active = active_alerts.find do |active_alert|
          active_alert["labels"]["id"] == alert["id"] &&
            Date.parse(active_alert["startsAt"]).to_s == Date.parse(alert["starts_at"]).to_s &&
            active_alert["status"]["state"] == "suppressed"
        end

        if active
          alert["description"] = active.dig("annotations", "description")
          alert["status"] = active["status"]["state"]
        end
      end
    end

    def publish_alert_counts
      MessageBus.publish("/alert-receiver",
        firing_alerts_count: Topic.firing_alerts.count,
        open_alerts_count: Topic.open_alerts.count
      )
    end
  end
end
