# frozen_string_literal: true

module Jobs
  class ProcessAlert < ::Jobs::Base
    sidekiq_options retry: false

    include AlertPostMixin

    def execute(args)
      @token = args[:token]
      params = args[:params]

      DistributedMutex.synchronize("prom-alert-#{@token}") do
        receiver = PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, @token)

        process_alerts(receiver, params)
      end
    end

    private

    def group_key(params)
      params["commonLabels"]["alertname"]
    end

    def process_alerts(receiver, params)
      new_alerts = parse_alerts(params["alerts"], external_url: params["externalURL"])

      topic = Topic.find_by(id: receiver[:topic_map][group_key(params)], closed: false)

      if topic
        new_alerts.each { |a| a[:topic_id] = topic.id }
        topic_ids = AlertReceiverAlert.update_alerts(new_alerts)
        return if topic_ids.empty? # No changes were made

        topic.custom_fields[TOPIC_BODY] = params["commonAnnotations"]["topic_body"]
        topic.custom_fields[BASE_TITLE] = title_from_params(params)
        topic.save_custom_fields if !topic.custom_fields_clean?

        revise_topic(topic: topic, ensure_tags: tags_from_params(params))
      elsif params["status"] == "resolved"
        # We don't care about resolved alerts if we've closed the topic
      else
        topic = create_new_topic(receiver, params, new_alerts)
        new_alerts.each { |a| a[:topic_id] = topic.id }
        AlertReceiverAlert.update_alerts(new_alerts)
      end
    end

    def title_from_params(params)
      params["commonAnnotations"]["topic_title"] ||
        "#{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"
    end

    def tags_from_params(params)
      tags = []
      tags += Array(params["commonLabels"]["datacenter"])
      tags += Array(params["commonAnnotations"]["topic_tags"]&.split(","))
      tags
    end

    def create_new_topic(receiver, params, new_alerts)
      base_title = title_from_params(params)

      firing_count = new_alerts.filter { |a| a[:status] == "firing" }.count
      topic_title = generate_title(base_title, firing_count)

      topic_body = params["commonAnnotations"]["topic_body"]

      tags = tags_from_params(params)
      tags << FIRING_TAG.dup if firing_count > 0

      PostCreator
        .create!(
          Discourse.system_user,
          raw:
            first_post_body(
              topic_body: topic_body,
              prev_topic_id: receiver["topic_map"][group_key(params)],
            ),
          category: Category.where(id: receiver[:category_id]).pluck(:id).first,
          title: topic_title,
          tags: tags,
          skip_validations: true,
        )
        .topic
        .tap do |t|
          t.custom_fields[TOPIC_BODY] = topic_body
          t.custom_fields[BASE_TITLE] = base_title
          if prev_topic_id = receiver["topic_map"][group_key(params)]
            t.custom_fields[PREVIOUS_TOPIC] = prev_topic_id
          end

          t.save_custom_fields

          receiver[:topic_map][group_key(params)] = t.id

          PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, @token, receiver)

          assignee =
            if username = params["commonAnnotations"]["topic_assignee"]
              User.where("username_lower = ?", username.downcase).first
            elsif group_name = params["commonAnnotations"]["topic_group_assignee"]
              Group.where("LOWER(name) = ?", group_name.downcase).first
            end

          assign_alert(t, receiver, assignee: assignee)
        end
    end

    def assign_alert(topic, receiver, assignee: nil)
      return unless SiteSetting.prometheus_alert_receiver_enable_assign

      Assigner.new(topic, Discourse.system_user).assign(assignee) if assignee
    end
  end
end
