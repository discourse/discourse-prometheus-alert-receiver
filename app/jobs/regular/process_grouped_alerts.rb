module Jobs
  class ProcessGroupedAlerts < Jobs::Base
    include AlertPostMixin

    def execute(args)
      token = args[:token]
      data = args[:data]
      external_url = args[:external_url]

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      data.each do |group|
        group_key = group["groupKey"]
        topic = Topic.find_by(id: receiver[:topic_map][group_key])

        if topic
          group["blocks"].each do |block|
            active_alerts = block["alerts"]
            annotations = active_alerts.first["annotations"]

            stored_alerts = begin
              key = ::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
              topic.custom_fields[key]&.dig('alerts') || []
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
              topic_title: annotations["topic_title"]
            )

            post = topic.posts.first

            if post.raw.chomp != raw.chomp || topic.title != title
              post = topic.posts.first

              PostRevisor.new(post, topic).revise!(
                Discourse.system_user,
                {
                  title: title,
                  raw: raw
                },
                skip_validations: true,
                validate_topic: true # This is a very weird API
              )
            end

            MessageBus.publish("/alert-receiver",
              firing_alerts_count: Topic.firing_alerts.count
            )
          end
        end
      end
    end

    private

    def silence_alerts(stored_alerts, active_alerts)
      stored_alerts.each do |alert|
        stored = active_alerts.find do |active_alert|
          active_alert["labels"]["id"] == alert["id"] &&
            active_alert["startsAt"] == alert["starts_at"] &&
            is_suppressed?(active_alert["status"]["state"])
        end

        alert["status"] = stored["status"]["state"] if stored
      end
    end
  end
end
