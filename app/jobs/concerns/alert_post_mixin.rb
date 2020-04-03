# frozen_string_literal: true

module AlertPostMixin
  extend ActiveSupport::Concern

  FIRING_TAG = "firing".freeze
  HIGH_PRIORITY_TAG = "high-priority".freeze
  NEXT_BUSINESS_DAY_SLA = "nbd".freeze
  MAX_DISPLAY_GROUP_SIZE = 100
  HISTORY_COLLAPSE_THRESHOLD = 50

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
      output += "## :fire: #{I18n.t("prom_alert_receiver.post.headers.firing")}\n\n"
      output = generate_alert_items(firing_alerts, output)
    end

    if silenced_alerts.present?
      output += "\n\n# :shushing_face: Silenced Alerts\n\n"
      output = generate_alert_items(silenced_alerts, output)
    end

    {
      "history" => resolved_alerts,
      "stale" => stale_alerts
    }.each do |header, alerts|
      if alerts.present?
        header = I18n.t("prom_alert_receiver.post.headers.#{header}")
        output += "\n\n## #{header}\n\n"
        output = generate_alert_items(alerts, output, collapse: alerts.length > HISTORY_COLLAPSE_THRESHOLD)
      end
    end

    output
  end

  def thead(alerts, datacenter, external_link)
    headers = "| [#{datacenter}](#{external_link}) | |"
    cells = "| --- | --- |"

    if alerts.any? { |alert| alert['description'] }
      headers += " |"
      cells += " --- |"
    end

    headers += " |"
    cells += " --- |"

    "#{headers}\n#{cells}"
  end

  def alert_item(alert)
    item = "| [#{alert['id']}](#{alert_link(alert)}) | #{alert_time_range(alert)} |"

    if description = alert['description']
      item += " #{description} |"
    end

    actions = []

    link = logs_link(alert)
    actions << "[:file_folder:](#{link})" if link.present?

    link = grafana_link(alert)
    actions << "[:bar_chart:](#{link})" if link.present?

    item += " <div>#{ actions.join(" ") }</div> |" if actions.present?

    item
  end

  def alert_time_range(alert)
    if alert['ends_at']
      "#{local_date(alert['starts_at'])} to #{local_date(alert['ends_at'], alert['starts_at'])}"
    else
      "active since #{local_date(alert['starts_at'])}"
    end
  end

  def local_date(time, starts_at = nil)
    parsed = Time.zone.parse(time)
    format = "L HH:mm"

    if starts_at.present?
      from = Time.zone.parse(starts_at)
      format = "HH:mm" if from.at_beginning_of_day == parsed.at_beginning_of_day
    end

    date = +<<~DATE
    [date=#{parsed.strftime("%Y-%m-%d")} time=#{parsed.strftime("%H:%M:%S")} format="#{format}" displayedTimezone="UTC" timezones="Europe/Paris\\|America/Los_Angeles\\|Asia/Singapore\\|Australia/Sydney"]
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
    url_params['g0.end_input']   = "#{(end_t + 300).strftime("%Y-%m-%d %H:%M")}"
    url_params['g0.tab'] = ["0"]
    url.query = URI.encode_www_form(url_params)
    url.to_s
  end

  def logs_link(alert)
    return if alert['logs_url'].blank?

    url = "#{alert['logs_url']}#/discover"
    begin_t = Time.parse(alert['starts_at'])
    end_t   = Time.parse(alert['ends_at']) rescue Time.zone.now

    "#{url}?_g=(time:(from:'#{begin_t.to_s(:iso8601)}',mode:absolute,to:'#{end_t.to_s(:iso8601)}'))"
  end

  def grafana_link(alert)
    return if alert['grafana_url'].blank?

    url = URI(alert['grafana_url'])
    url_params = CGI.parse(url.query || "")

    begin_t = Time.parse(alert['starts_at'])
    end_t   = Time.parse(alert['ends_at']) rescue Time.zone.now
    url_params['from'] = "#{begin_t.to_i}000"
    url_params['to'] = "#{end_t.to_i}000"
    url.query = URI.encode_www_form(url_params)
    url.to_s
  end

  def get_grafana_dashboard_url(alert, grafana_url)
    return if alert.blank? || grafana_url.blank?

    dashboard_path = alert.dig('annotations', 'grafana_dashboard_path')
    return if dashboard_path.blank?

    "#{grafana_url}#{dashboard_path}"
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    created_at = Topic.where(id: topic_id).pluck(:created_at).first
    return "" unless created_at

    "[Previous alert](#{Discourse.base_url}/t/#{topic_id}) #{local_date(created_at.to_s)}\n\n"
  end

  def generate_title(base_title, alert_history)
    firing_count = alert_history&.count { |alert| is_firing?(alert["status"]) }
    if firing_count > 0
      I18n.t("prom_alert_receiver.topic_title.firing", base_title: base_title, count: firing_count)
    else
      I18n.t("prom_alert_receiver.topic_title.not_firing", base_title: base_title)
    end
  end

  def first_post_body(receiver:,
                      topic_body: "",
                      alert_history:,
                      prev_topic_id:)

    output = ""
    output += "#{topic_body}\n\n"
    output += "#{prev_topic_link(prev_topic_id)}\n\n" if prev_topic_id
    output += "#{render_alerts(alert_history)}\n"
  end

  def revise_topic(topic:, title:, raw:, datacenters:, firing: nil, high_priority: false)
    post = topic.first_post
    title_changed = topic.title != title
    skip_revision = true

    if post.raw.strip != raw.strip || title_changed || !firing.nil?
      post = topic.first_post

      fields = {
        title: title,
        raw: raw
      }

      fields[:tags] ||= []

      if datacenters.present?
        fields[:tags] = topic.tags.pluck(:name)
        fields[:tags].concat(datacenters)
        fields[:tags].uniq!
      end

      fields[:tags] << HIGH_PRIORITY_TAG.dup if high_priority

      if firing
        fields[:tags] << FIRING_TAG.dup
      else
        fields[:tags].delete(FIRING_TAG)
      end

      PostRevisor.new(post, topic).revise!(
        Discourse.system_user,
        fields,
        skip_revision: skip_revision,
        skip_validations: true,
        validate_topic: true # This is a very weird API
      )
      if firing && title_changed
        topic.update_column(:bumped_at, Time.now)
        TopicTrackingState.publish_latest(topic)
      end
    end
  end

  def is_suppressed?(status)
    "suppressed".freeze == status
  end

  def is_firing?(status)
    status == "firing".freeze
  end

  def datacenters(alerts)
    alerts.each_with_object(Set.new) do |alert, set|
      set << alert['datacenter'] if alert['datacenter']
    end.to_a
  end

  def generate_alert_items(grouped_alerts, output, collapse: false)
    output += "<div data-plugin='prom-alerts-table'>\n\n"

    grouped_alerts
      .group_by { |alert| [alert['datacenter'], alert['external_url']] }
      .each do |(datacenter, external_url), alerts|

      is_truncated = truncated_count = nil
      if alerts.length > MAX_DISPLAY_GROUP_SIZE
        is_truncated = true
        truncated_count = alerts.length - MAX_DISPLAY_GROUP_SIZE
        alerts = alerts.first(MAX_DISPLAY_GROUP_SIZE)
      end

      output += "[details=#{datacenter} (#{alerts.count})]" if collapse
      output += "#{thead(alerts, datacenter, external_url)}\n"
      output += alerts.first(MAX_DISPLAY_GROUP_SIZE).map { |alert| alert_item(alert) }.join("\n")
      output += "\n|[#{I18n.t("prom_alert_receiver.post.more", count: truncated_count)}](#{external_url})|" if is_truncated
      output += "\n[/details]" if collapse
      output += "\n\n"
    end

    output += "</div>"
    output
  end
end
