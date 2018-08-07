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

      if receiver[:assignee_group_id]
        assigned_topic(receiver, params)
      else
        add_post(receiver, params)
      end

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token, receiver
      )
    end

    private

    def add_post(receiver, params)
      category = Category.find_by(id: receiver[:category_id])
      topic = Topic.find_by(id: receiver[:topic_id])

      post_attributes =
        if topic
          {
            topic_id: receiver[:topic_id]
          }
        else
          {
            category: category.id,
            title: "#{params["commonAnnotations"]["title"]} - #{Date.today.to_s}"
          }
        end

      post = PostCreator.create!(Discourse.system_user, {
        raw: params["commonAnnotations"]["raw"]
      }.merge(post_attributes))

      receiver[:topic_id] = post.topic_id
    end

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
          datacenter: params["commonLabels"]["datacenter"],
          topic_title: params["commonAnnotations"]["topic_title"] ||
            "alert: #{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}",
          created_at: topic.created_at
        )

        post = topic.posts.first

        if post.raw.strip != raw.strip || topic.title != title
          post = topic.posts.first

          PostRevisor.new(post, topic).revise!(
            Discourse.system_user,
            {
              title: title,
              raw: raw
            },
            force_new_version: true,
            skip_validations: true,
            validate_topic: true # This is a very weird API
          )
        end
      elsif params["status"] == "resolved"
        # We don't care about resolved alerts if we've closed the topic
        return
      else
        alert_history = update_alert_history([], params["alerts"])
        topic = create_new_topic(receiver, params, alert_history)
        receiver[:topic_map][params["groupKey"]] = topic.id
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
        "alert: #{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"

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
          datacenter: datacenter,
          topic_title: topic_title,
          created_at: DateTime.now
        ),
        skip_validations: true
      ).topic.tap do |t|
        if params["commonAnnotations"]["topic_assignee"]
          assignee = User.find_by(username: params["commonAnnotations"]["topic_assignee"])
        end

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

        t.save_custom_fields(true)

        assignee ||= begin
          if user_on_rotation = OpsgenieSchedule.users_on_rotation.sample
            assignee = User.find_by_username_or_email(user_on_rotation)

            if !assignee
              Rails.logger.warn(
                "Failed to assign alert topic to '#{user_on_rotation}'"
              )
            end

            assignee
          else
            random_group_member(receiver)
          end
        end

        if assignee
          TopicAssigner.new(t, Discourse.system_user).assign(assignee)
        end
      end
    end

    def random_group_member(receiver)
      Group.find_by(id: receiver[:assignee_group_id]).users.sample
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
