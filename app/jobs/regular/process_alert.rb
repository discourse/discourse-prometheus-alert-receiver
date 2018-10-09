module Jobs
  class ProcessAlert < Jobs::Base
    include AlertPostMixin

    def execute(args)
      token = args[:token]
      params = args[:params]

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      assigned_topic(receiver, params)

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token, receiver
      )
    end

    private

    def assigned_topic(receiver, params)
      topic = Topic.find_by(
        id: receiver[:topic_map][params["groupKey"]],
        closed: false
      )

      if topic
        prev_alert_history = begin
          key = ::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
          topic.custom_fields[key]&.dig('alerts') || []
        end

        alert_history = update_alert_history(prev_alert_history, params["alerts"])

        raw = first_post_body(
          receiver: receiver,
          external_url: params["externalURL"],
          topic_body: params["commonAnnotations"]["topic_body"],
          alert_history: alert_history,
          prev_topic_id: topic.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD]
        )

        title = topic_title(
          alert_history: alert_history,
          topic_title: params["commonAnnotations"]["topic_title"] ||
            "#{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}",
          created_at: topic.created_at
        )

        revise_topic(
          topic: topic,
          title: title,
          raw: raw,
          datacenter: params["commonLabels"]["datacenter"]
        )

        assign_alert(topic, receiver) unless topic.assigned_to_user
      elsif params["status"] == "resolved"
        # We don't care about resolved alerts if we've closed the topic
        return
      else
        alert_history = update_alert_history([], params["alerts"])
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
      topic_title = params["commonAnnotations"]["topic_title"] ||
        "#{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"

      datacenter = params["commonLabels"]["datacenter"]
      topic_body = params["commonAnnotations"]["topic_body"]

      PostCreator.create!(Discourse.system_user,
        raw: first_post_body(
          receiver: receiver,
          external_url: params["externalURL"],
          topic_body: topic_body,
          alert_history: alert_history,
          prev_topic_id: receiver["topic_map"][params["groupKey"]]
        ),
        category: Category.where(id: receiver[:category_id]).pluck(:id).first,
        title: topic_title(
          firing: params["status"],
          topic_title: topic_title,
          created_at: DateTime.now
        ),
        tags: [datacenter],
        skip_validations: true
      ).topic.tap do |t|
        t.custom_fields[
          DiscoursePrometheusAlertReceiver::TOPIC_BODY_CUSTOM_FIELD
        ] = topic_body

        t.custom_fields[
          DiscoursePrometheusAlertReceiver::TOPIC_TITLE_CUSTOM_FIELD
        ] = topic_title

        t.custom_fields[
          DiscoursePrometheusAlertReceiver::DATACENTER_CUSTOM_FIELD
        ] = datacenter

        if receiver["topic_map"][params["groupKey"]]
          t.custom_fields[
            DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD
          ] = receiver["topic_map"][params["groupKey"]]
        end

        receiver[:topic_map][params["groupKey"]] = t.id
        t.save_custom_fields(true)

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
      assignee ||= begin
        emails = OpsgenieSchedule.users_on_rotation

        possible_users =
          if emails.length == 0
            []
          else
            users = User.where('email': OpsgenieSchedule.users_on_rotation)
            if group_id = receiver[:assignee_group_id]
              users = users.joins(:group_users).where(group_id: group_id)
            end
            users
          end

        assignee = possible_users.sample || random_group_member(receiver[:assignee_group_id])
      end

      if assignee
        TopicAssigner.new(topic, Discourse.system_user).assign(assignee)
      end
    end

    def update_alert_history(previous_history, active_alerts)
      # Sadly, this is the easiest way to get a deep dup
      JSON.parse(previous_history.to_json).tap do |new_history|
        active_alerts.sort_by { |a| a['startsAt'] }.each do |alert|
          stored_alert = new_history.find do |p|
            p['id'] == alert['labels']['id'] &&
              DateTime.parse(p['starts_at']).to_s == DateTime.parse(alert['startsAt']).to_s
          end

          alert_description = alert.dig('annotations', 'description')
          firing = is_firing?(alert['status'])

          if stored_alert.nil? && firing
            stored_alert = {
              'id' => alert['labels']['id'],
              'starts_at' => alert['startsAt'],
              'graph_url' => alert['generatorURL'],
              'status' => alert['status'],
              'description' => alert_description
            }

            new_history << stored_alert
          elsif stored_alert
            stored_alert['status'] = alert['status']
            stored_alert['description'] = alert_description
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
