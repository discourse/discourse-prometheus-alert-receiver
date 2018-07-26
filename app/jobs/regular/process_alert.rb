module Jobs
  class ProcessAlert < Jobs::Base
    def execute(args)
      receiver = args[:receiver]
      params = args[:params]

      Topic.transaction do
        if receiver[:assignee_group_id]
          assigned_topic(receiver, params)
        else
          add_post(receiver, params)
        end
      end

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        args[:token], receiver
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
        Rails.logger.debug("DPAR") { "Using existing topic #{topic.id}" }

        prev_alert_history = begin
          key = ::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
          topic.custom_fields[key]&.dig('alerts') || []
        end

        alert_history = update_alert_history(prev_alert_history, params["alerts"])

        if alert_history != prev_alert_history
          Rails.logger.debug("DPAR") { "Alert history has changed; revising first post" }
          post = topic.posts.first

          PostRevisor.new(post, topic).revise!(
            Discourse.system_user,
            title: topic_title(params, topic: topic),
            raw: first_post_body(
              receiver,
              params,
              alert_history,
              topic.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD]
            )
          )
        end
      elsif params["status"] == "resolved"
        Rails.logger.debug("DPAR") { "Received resolved alert on closed topic; ignoring" }
        # We don't care about resolved alerts if we've closed the topic
        return
      else
        Rails.logger.debug("DPAR") { "New topic creation required" }
        alert_history = update_alert_history([], params["alerts"])
        topic = create_new_topic(receiver, params, alert_history)
        Rails.logger.debug("DPAR") { "Created new topic, id=#{topic.id}" }
        receiver[:topic_map][params["groupKey"]] = topic.id
      end

      # Custom fields don't handle array data very well, even when they're
      # explicitly declared as JSON fields, so we have to wrap our array in
      # a single-element hash.
      topic.custom_fields[::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD] = { 'alerts' => alert_history }
      topic.save_custom_fields
    end

    def create_new_topic(receiver, params, alert_history)
      PostCreator.create!(Discourse.system_user,
        raw: first_post_body(receiver, params, alert_history, receiver["topic_map"][params["groupKey"]]),
        category: Category.where(id: receiver[:category_id]).pluck(:id).first,
        title: topic_title(params),
        skip_validations: true
      ).topic.tap do |t|
        if params["commonAnnotations"]["topic_assignee"]
          Rails.logger.debug("DPAR") { "Forcing assignment of user #{params["commonAnnotations"]["topic_assignee"].inspect}" }
          assignee = User.find_by(username: params["commonAnnotations"]["topic_assignee"])
        end

        if receiver["topic_map"][params["groupKey"]]
          Rails.logger.debug("DPAR") { "Linking to previous topic #{receiver["topic_map"][params["groupKey"]]}" }
          t.custom_fields[::DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD] = receiver["topic_map"][params["groupKey"]]
          t.save_custom_fields
        end

        assignee ||= random_group_member(receiver)

        # Force assign to TGX first
        # See https://dev.discourse.org/t/feeding-most-alerts-into-dev-rather-than-chat/3416/22?u=tgxworld
        assignee = User.find_by_username('tgxworld') if Rails.env.production?
        TopicAssigner.new(t, Discourse.system_user).assign(assignee) unless assignee.nil?
      end
    end

    def random_group_member(receiver)
      group = Group.find_by(id: receiver[:assignee_group_id])
      group.users.sort_by { rand }.first
    end

    def first_post_body(receiver, params, alert_history, prev_topic_id)
      <<~BODY
      #{params["externalURL"]}

      #{params["commonAnnotations"]["topic_body"] || ""}

      #{prev_topic_link(prev_topic_id)}

      #{render_alerts(alert_history)}
      BODY
    end

    def render_alerts(alert_history)
      firing_alerts = []
      resolved_alerts = []

      alert_history.each do |alert|
        status = alert['status']

        if is_firing?(status)
          firing_alerts << alert
        elsif status == 'resolved'
          resolved_alerts << alert
        end
      end

      output = ""

      if firing_alerts.length > 0
        output += "# :fire: Firing Alerts\n\n"

        output += firing_alerts.map do |alert|
          " * [#{alert_label(alert)}](#{alert_link(alert)})"
        end.join("\n")
      end

      if resolved_alerts.length > 0
        output += "\n\n# Alert History\n\n"

        output += resolved_alerts.map do |alert|
          " * [#{alert_label(alert)}](#{alert_link(alert)})"
        end.join("\n")
      end

      output
    end

    def alert_label(alert)
      "#{alert['id']} (#{alert_time_range(alert)})"
    end

    def alert_time_range(alert)
      if alert['ends_at']
        "#{friendly_time(alert['starts_at'])} to #{friendly_time(alert['ends_at'])}"
      else
        "active since #{friendly_time(alert['starts_at'])}"
      end
    end

    def friendly_time(t)
      Time.parse(t).strftime("%Y-%m-%d %H:%M:%S UTC")
    end

    def topic_title(params, topic: nil)
      params["groupLabels"]

      firing =
        if topic
          key = DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD

          (topic.custom_fields[key]["alerts"] || []).all? do |alert|
            is_firing?(params["status"])
          end
        else
          is_firing?(params["status"])
        end

      (firing ? ":fire: " : ":white_check_mark: ") +
        (params["commonLabels"]["datacenter"] || "") +
        (params["commonAnnotations"]["topic_title"] || "alert: #{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}")
    end

    def alert_link(alert)
      url = URI(alert['graph_url'])
      url_params = CGI.parse(url.query)

      begin_t = Time.parse(alert['starts_at'])
      end_t   = Time.parse(alert['ends_at']) rescue Time.now
      url_params['g0.range_input'] = "#{(end_t - begin_t).to_i + 600}s"
      url_params['g0.end_input']   = "#{end_t.strftime("%Y-%m-%d %H:%M")}"
      url.query = URI.encode_www_form(url_params)

      url.to_s
    end

    def prev_topic_link(topic_id)
      return "" if topic_id.nil?
      "([Previous topic for this alert](#{Discourse.base_url}/t/#{topic_id}).)\n\n"
    end

    def is_firing?(status)
      status == "firing".freeze
    end

    def update_alert_history(previous_history, active_alerts)
      # Sadly, this is the easiest way to get a deep dup
      JSON.parse(previous_history.to_json).tap do |new_history|
        active_alerts.sort_by { |a| a['startsAt'] }.each do |alert|
          Rails.logger.debug("DPAR") { "Processing webhook alert #{alert.inspect}" }

          stored_alert = new_history.find do |p|
            p['id'] == alert['labels']['id'] && p['starts_at'] == alert['startsAt']
          end

          if stored_alert.nil? && is_firing?(alert['status'])
            stored_alert = {
              'id' => alert['labels']['id'],
              'starts_at' => alert['startsAt'],
              'graph_url' => alert['generatorURL'],
              'status' => alert['status']
            }

            new_history << stored_alert
          end

          Rails.logger.debug("DPAR") { "Stored alert is #{stored_alert.inspect}" }

          if alert['status'] == "resolved" && stored_alert && stored_alert['ends_at'].nil?
            Rails.logger.debug("DPAR") { "Marking alert as resolved" }
            stored_alert['ends_at'] = alert['endsAt']
            stored_alert['status'] = alert['status']
          end
        end
      end
    end
  end
end
