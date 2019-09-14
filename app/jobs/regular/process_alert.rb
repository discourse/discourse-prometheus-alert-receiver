# frozen_string_literal: true

module Jobs
  class ProcessAlert < ::Jobs::Base
    include AlertPostMixin

    def execute(args)
      @token = args[:token]
      params = args[:params]

      DistributedMutex.synchronize("prom-alert-#{@token}") do

        receiver = PluginStore.get(
          ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
          @token
        )

        assigned_topic(receiver, params)
      end
    end

    private

    def group_key(params)
      params["commonLabels"]["alertname"]
    end

    def assigned_topic(receiver, params)
      topic = Topic.find_by(
        id: receiver[:topic_map][group_key(params)],
        closed: false
      )

      if topic
        prev_alert_history = begin
          key = ::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
          topic.custom_fields[key]&.dig('alerts') || []
        end

        alert_history = update_alert_history(prev_alert_history, params["alerts"],
          datacenter: params["commonLabels"]["datacenter"],
          external_url: params["externalURL"]
        )

        raw = first_post_body(
          receiver: receiver,
          topic_body: params["commonAnnotations"]["topic_body"],
          alert_history: alert_history,
          prev_topic_id: topic.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD]
        )

        base_title = params["commonAnnotations"]["topic_title"] ||
          "#{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"

        title = generate_title(base_title, alert_history)

        revise_topic(
          topic: topic,
          title: title,
          raw: raw,
          datacenters: datacenters(alert_history),
          firing: alert_history.any? { |alert| is_firing?(alert["status"]) },
          high_priority: params["commonLabels"]["response_sla"] != AlertPostMixin::NEXT_BUSINESS_DAY_SLA
        )

        assign_alert(topic, receiver) unless topic.assigned_to_user
      elsif params["status"] == "resolved"
        # We don't care about resolved alerts if we've closed the topic
        return
      else
        alert_history = update_alert_history([], params["alerts"],
          datacenter: params["commonLabels"]["datacenter"],
          external_url: params["externalURL"]
        )

        topic = create_new_topic(receiver, params, alert_history)
      end

      # Custom fields don't handle array data very well, even when they're
      # explicitly declared as JSON fields, so we have to wrap our array in
      # a single-element hash.
      topic.custom_fields[::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD] = { 'alerts' => alert_history }
      topic.save_custom_fields

      MessageBus.publish("/alert-receiver",
        firing_alerts_count: Topic.firing_alerts.count
      )
    end

    def create_new_topic(receiver, params, alert_history)
      base_title = params["commonAnnotations"]["topic_title"] ||
        "#{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"

      topic_title = generate_title(base_title, alert_history)

      datacenter = params["commonLabels"]["datacenter"]
      topic_body = params["commonAnnotations"]["topic_body"]

      tags = [datacenter]

      tags << AlertPostMixin::FIRING_TAG.dup if is_firing?(params['status'])

      if params["commonLabels"]["response_sla"] != AlertPostMixin::NEXT_BUSINESS_DAY_SLA
        tags << AlertPostMixin::HIGH_PRIORITY_TAG.dup
      end

      PostCreator.create!(Discourse.system_user,
        raw: first_post_body(
          receiver: receiver,
          topic_body: topic_body,
          alert_history: alert_history,
          prev_topic_id: receiver["topic_map"][group_key(params)]
        ),
        category: Category.where(id: receiver[:category_id]).pluck(:id).first,
        title: topic_title,
        tags: tags,
        skip_validations: true
      ).topic.tap do |t|
        t.custom_fields[
          DiscoursePrometheusAlertReceiver::TOPIC_BODY_CUSTOM_FIELD
        ] = topic_body

        t.custom_fields[
          DiscoursePrometheusAlertReceiver::TOPIC_BASE_TITLE_CUSTOM_FIELD
        ] = base_title

        t.custom_fields[
          DiscoursePrometheusAlertReceiver::TOPIC_TITLE_CUSTOM_FIELD
        ] = topic_title

        if receiver["topic_map"][group_key(params)]
          t.custom_fields[
            DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD
          ] = receiver["topic_map"][group_key(params)]
        end

        receiver[:topic_map][group_key(params)] = t.id

        PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
          @token, receiver
        )

        assignee =
          if params["commonAnnotations"]["topic_assignee"]
            User.find_by(username: params["commonAnnotations"]["topic_assignee"])
          elsif params["commonAnnotations"]["group_topic_assignee"]
            random_group_member(params["commonAnnotations"]["group_topic_assignee"])
          end

        assign_alert(t, receiver, assignee: assignee)
      end
    end

    def random_group_member(id_or_name)
      attributes =
        if id_or_name.to_i != 0
          { id: id_or_name.to_i }
        else
          "LOWER(name) LIKE '#{id_or_name}'"
        end

      Group.find_by(attributes).users.sample
    end

    def assign_alert(topic, receiver, assignee: nil)
      return unless SiteSetting.prometheus_alert_receiver_enable_assign

      assignee ||= begin
        emails = OpsgenieSchedule.users_on_rotation

        possible_users =
          if emails.length == 0
            []
          else
            users = User.with_email(OpsgenieSchedule.users_on_rotation)

            if group_id = receiver[:assignee_group_id]
              users = users.joins(:group_users).where(
                group_users: { group_id: group_id }
              )
            end

            users
          end

        assignee = possible_users.sample || random_group_member(receiver[:assignee_group_id])
      end

      if assignee
        TopicAssigner.new(topic, Discourse.system_user).assign(assignee)
      end
    end

    def update_alert_history(previous_history, active_alerts,
                             datacenter:,
                             external_url:)

      # Sadly, this is the easiest way to get a deep dup
      JSON.parse(previous_history.to_json).tap do |new_history|
        active_alerts.sort_by { |a| a['startsAt'] }.each do |alert|

          stored_alert = new_history.find do |p|
            p['id'] == alert['labels']['id'] &&
              p['datacenter'] == datacenter &&
              p["status"] != "resolved"
          end

          alert_description = alert.dig('annotations', 'description')
          firing = is_firing?(alert['status'])

          if stored_alert.nil? && firing
            stored_alert = {
              'id' => alert['labels']['id'],
              'starts_at' => alert['startsAt'],
              'graph_url' => alert['generatorURL'],
              'status' => alert['status'],
              'description' => alert_description,
              'datacenter' => datacenter,
              'external_url' => external_url
            }

            new_history << stored_alert
          elsif stored_alert
            stored_alert['status'] = alert['status']
            stored_alert['description'] = alert_description
            stored_alert['datacenter'] = datacenter
            stored_alert['external_url'] = external_url
            stored_alert.delete('ends_at') if firing
          end

          if alert['status'] == "resolved" && stored_alert && stored_alert['ends_at'].nil?
            stored_alert['ends_at'] = alert['endsAt']
          end
        end
      end
    end
  end
end
