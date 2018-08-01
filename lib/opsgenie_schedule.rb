require 'msgpack'

class OpsgenieSchedule
  API_PATH = 'https://api.eu.opsgenie.com/v2'.freeze
  SCHEDULES_PATH = '/schedules'.freeze
  HOURS = (0..23).to_a.freeze

  def self.users_on_rotation
    return [] if api_key.blank?
    timezone = user_rotations['timezone']

    user_rotations['rotations'].select do |(start_hour, end_hour)|
      current_hour = Time.use_zone(timezone) { Time.zone.now.hour }

      if start_hour > end_hour
        (HOURS - (end_hour..(start_hour - 1)).to_a).include?(current_hour)
      else
        (start_hour..(end_hour - 1)) === current_hour
      end
    end.values.flatten
  end

  private

  def self.user_rotations
    if cached_rotations = $redis.get(redis_key)
      return MessagePack.unpack(cached_rotations)
    end

    schedule_ids = get(SCHEDULES_PATH)["data"].map do |schedule|
      schedule["id"]
    end

    new_rotations = {}

    schedule_ids.each do |schedule_id|
      data = get("#{SCHEDULES_PATH}/#{schedule_id}")["data"]
      new_rotations['timezone'] = data['timezone']
      rotations = data["rotations"]

      rotations.each do |rotation|
        restriction = rotation['timeRestriction']['restriction']
        start_hour = restriction['startHour']
        end_hour = restriction['endHour']
        emails = rotation["participants"].map { |p| p["username"] }
        new_rotations['rotations'] ||= {}
        new_rotations['rotations'][[start_hour, end_hour]] = emails
      end
    end

    $redis.setex(redis_key, 1.day, new_rotations.to_msgpack)
    new_rotations
  end

  def self.redis_key
    'discourse-prometheus-alert-receiver:rotations'
  end

  def self.api_key
    SiteSetting.prometheus_alert_receiver_opsgenie_api_key
  end

  def self.get(path)
    uri = URI("#{API_PATH}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true if uri.scheme == 'https'
    request = Net::HTTP::Get.new(uri.request_uri)

    request.initialize_http_header(
      "Authorization" => "GenieKey #{api_key}"
    )

    response = http.request(request)

    unless response.kind_of?(Net::HTTPSuccess)
      raise StandardError, "(#{response.code}) #{response.body}"
    end

    JSON.parse(response.body)
  end
end
