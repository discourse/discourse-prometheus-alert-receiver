module AlertPostMixin
  extend ActiveSupport::Concern

  private

  def render_alerts(alert_history)
    firing_alerts = []
    resolved_alerts = []
    silenced_alerts = []
    stale_alerts = []

    alert_history.each do |alert|
      status = alert['status']

      case
      when is_firing?(status)
        firing_alerts << alert
      when status == 'resolved'
        resolved_alerts << alert
      when status == 'stale'
        stale_alerts << alert
      when is_suppressed?(status)
        silenced_alerts << alert
      end
    end

    output = ""

    if firing_alerts.present?
      output += "# :fire: Firing Alerts\n\n"

      output += firing_alerts.map do |alert|
        <<~BODY
        #{alert_item(alert)}
        #{alert['description']}
        BODY
      end.join("\n")
    end

    if silenced_alerts.present?
      output += "\n\n# :shushing_face: Silenced Alerts\n\n"

      output += silenced_alerts.map do |alert|
        <<~BODY
        #{alert_item(alert)}
        #{alert['description']}
        BODY
      end.join("\n")
    end

    {
      "Alert History" => resolved_alerts,
      "Stale Alerts" => stale_alerts
    }.each do |header, alerts|
      if alerts.present?
        output += "\n\n# #{header}\n\n"
        output += alerts.map { |alert| alert_item(alert) }.join("\n")
      end
    end

    output
  end

  def alert_item(alert)
    " * [#{alert_label(alert)}](#{alert_link(alert)}) (#{alert_time_range(alert)})"
  end

  def alert_label(alert)
    alert['id']
  end

  def alert_time_range(alert)
    if alert['ends_at']
      "#{local_date(alert['starts_at'])} to #{local_date(alert['ends_at'])}"
    else
      "active since #{local_date(alert['starts_at'])}"
    end
  end

  def local_date(time)
    parsed = Time.zone.parse(time)

    date = <<~DATE
    [date=#{parsed.strftime("%Y-%m-%d")} time=#{parsed.strftime("%H:%M:%S")} format="L LTS" timezones="UTC|Europe/Paris|America/Los_Angeles|Asia/Singapore|Australia/Sydney"]
    DATE

    date.chomp!
    date
  end

  def alert_link(alert)
    url = URI(alert['graph_url'])
    url_params = CGI.parse(url.query)

    begin_t = Time.parse(alert['starts_at'])
    end_t   = Time.parse(alert['ends_at']) rescue Time.zone.now
    url_params['g0.range_input'] = "#{(end_t - begin_t).to_i + 600}s"
    url_params['g0.end_input']   = "#{end_t.strftime("%Y-%m-%d %H:%M")}"
    url.query = URI.encode_www_form(url_params)

    url.to_s
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    created_at = Topic.where(id: topic_id).pluck(:created_at).first
    return "" unless created_at

    "([Previous alert topic created.](#{Discourse.base_url}/t/#{topic_id}) #{local_date(created_at.to_s)})\n\n"
  end

  def topic_title(alert_history: nil, datacenter:, topic_title:, firing: nil, created_at:)
    firing ||= alert_history.any? do |alert|
      is_firing?(alert["status"])
    end

    (firing ? ":fire: " : "") +
      (datacenter ? "#{datacenter} " : "") +
      topic_title +
      " - #{Date.parse(created_at.to_s).to_s}"
  end

  def first_post_body(receiver:,
                      external_url:,
                      topic_body: "",
                      alert_history:,
                      prev_topic_id:)

    <<~BODY
    #{external_url}

    #{topic_body}

    #{prev_topic_link(prev_topic_id)}

    #{render_alerts(alert_history)}
    BODY
  end

  def revise_topic(topic, title, raw)
    post = topic.posts.first
    title_changed = topic.title != title
    skip_revision = !title_changed

    if post.raw.strip != raw.strip || title_changed
      post = topic.posts.first

      PostRevisor.new(post, topic).revise!(
        Discourse.system_user,
        {
          title: title,
          raw: raw
        },
        skip_revision: skip_revision,
        skip_validations: true,
        validate_topic: true # This is a very weird API
      )
    end
  end

  def is_suppressed?(status)
    "suppressed".freeze == status
  end

  def is_firing?(status)
    status == "firing".freeze
  end
end
