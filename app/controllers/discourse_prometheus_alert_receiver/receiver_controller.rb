require 'time'
require 'cgi'

module DiscoursePrometheusAlertReceiver
  class ReceiverController < ApplicationController
    skip_before_action :check_xhr,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       only: [:generate_receiver_url, :receive]

    def generate_receiver_url
      params.require(:category_id)

      category = Category.find_by(id: params[:category_id])
      raise Discourse::InvalidParameters unless category

      receiver_data = {
        category_id: category.id,
        created_at: Time.zone.now,
        created_by: current_user.id
      }

      if params["assignee_group_id"]
        group = Group.find_by(id: params[:assignee_group_id])
        raise Discourse::InvalidParameters unless group

        receiver_data[:assignee_group_id] = group.id
        receiver_data[:topic_map] = {}
      end

      token = SecureRandom.hex(32)

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token,
        receiver_data
      )

      if category.save
        url = "#{Discourse.base_url}/prometheus/receiver/#{token}"

        render json: success_json.merge(url: url)
      else
        render json: failed_json
      end
    end

    def receive
      token = params.require(:token)

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      raise Discourse::InvalidParameters unless receiver

      category = Category.find_by(id: receiver[:category_id])
      raise Discourse::InvalidParameters unless category

      if receiver[:assignee_group_id]
        assigned_topic(receiver, params)
      else
        add_post(receiver, params)
      end

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token, receiver
      )

      render json: success_json
    rescue ActiveRecord::RecordNotSaved => e
      render json: failed_json.merge(error: e.message)
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
      topic = Topic.find_by(id: receiver[:topic_map][params["groupKey"]], closed: false)

      if topic
        Rails.logger.debug("DPAR") { "Using existing topic #{topic.id}" }
        prev_alert_history = topic.custom_fields[::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD]['alerts'] rescue []
        alert_history = update_alert_history(prev_alert_history, params["alerts"])
        if alert_history != prev_alert_history
          Rails.logger.debug("DPAR") { "Alert history has changed; revising first post" }
          post = topic.posts.first
          PostRevisor.new(post).revise!(
            Discourse.system_user,
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
      topic.save!
    end

    def create_new_topic(receiver, params, alert_history)
      PostCreator.create!(Discourse.system_user,
        raw: first_post_body(receiver, params, alert_history, receiver["topic_map"][params["groupKey"]]),
        category: Category.find_by(id: receiver[:category_id]),
        title: topic_title(params),
        skip_validations: true,
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

        TopicAssigner.new(t, Discourse.system_user).assign(assignee) unless assignee.nil?
      end
    end

    def random_group_member(receiver)
      group = Group.find_by(id: receiver[:assignee_group_id])
      group.users.sort_by { rand }.first
    end

    def first_post_body(receiver, params, alert_history, prev_topic_id)
      (params["commonAnnotations"]["topic_body"] || "") + "\n\n" +
        prev_topic_link(prev_topic_id) +
        rendered_alert_history(alert_history)
    end

    def rendered_alert_history(alert_history)
      "# Alert History\n\n" +
        alert_history.map do |alert|
          " * [#{alert_label(alert)}](#{alert_link(alert)})"
        end.join("\n")
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

    def topic_title(params)
      params["groupLabels"].permit!
      params["commonAnnotations"]["topic_title"] || "Alert investigation required: #{params["groupLabels"].to_hash.map { |k, v| "#{k}: #{v}" }.join(", ")}"
    end

    def alert_link(alert)
      url = URI(alert['graph_url'])
      url_params = CGI.parse(url.query)

      begin_t = Time.parse(alert['starts_at'])
      end_t   = Time.parse(alert['ends_at']) rescue Time.now
      url_params['g0.range_input'] = "#{end_t - begin_t + 600}s"
      url_params['g0.end_input']   = "#{end_t.strftime("%Y-%m-%d %H:%M")}"
      url.query = URI.encode_www_form(url_params)

      url.to_s
    end

    def prev_topic_link(topic_id)
      return "" if topic_id.nil?

      "([Previous topic for this alert](#{Discourse.base_url}/t/#{topic_id}).)\n\n"
    end

    def update_alert_history(previous_history, active_alerts)
      # Sadly, this is the easiest way to get a deep dup
      JSON.parse(previous_history.to_json).tap do |new_history|
        active_alerts.sort_by { |a| a['startsAt'] }.each do |alert|
          stored_alert = new_history.find { |p| p['id'] == alert['labels']['id'] && p['starts_at'] == alert['startsAt'] }
          if stored_alert.nil? && alert['status'] == "firing"
            stored_alert = {
              'id'        => alert['labels']['id'],
              'starts_at' => alert['startsAt'],
              'graph_url' => alert['generatorURL'],
            }
            new_history << stored_alert
          end

          if alert['status'] == "resolved" && stored_alert && stored_alert['ends_at'].nil?
            stored_alert['ends_at'] = alert['endsAt']
          end
        end
      end
    end
  end
end
