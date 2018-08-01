require 'rails_helper'

RSpec.describe OpsgenieSchedule do
  before do
    api_key = SiteSetting.prometheus_alert_receiver_opsgenie_api_key = 'somekey'
    schedules_path = "#{OpsgenieSchedule::API_PATH}#{OpsgenieSchedule::SCHEDULES_PATH}"

    stub_request(:get, schedules_path)
      .with(
        headers: {
          'Authorization'=> "GenieKey #{api_key}"
        }
      )
      .to_return(status: 200, body: {
        "data": [
          {
            "id": "uuid1",
            "name": "Up",
            "description": "",
            "timezone": "Etc/UTC",
            "enabled": true,
            "ownerTeam": {
              "id": "uuid",
              "name": "someteam"
            },
            "rotations": []
          },
          {
            "id": "uuid2",
            "name": "Down",
            "description": "",
            "timezone": "Etc/UTC",
            "enabled": true,
            "ownerTeam": {
              "id": "uuid",
              "name": "someteam"
            },
            "rotations": []
          }
        ],
        "expandable": [
          "rotation"
        ],
        "took": 0.0011,
        "requestId": "uuid"
      }.to_json)

    stub_request(:get, "#{schedules_path}/uuid1")
      .with(
        headers: {
          'Authorization'=> "GenieKey #{api_key}"
        }
      )
      .to_return(status: 200, body: {
        "data": {
          "id": "uuid",
          "name": "East",
          "description": "",
          "timezone": "Etc/UTC",
          "enabled": true,
          "ownerTeam": {
            "id": "uuid",
            "name": "someteamname"
          },
          "rotations": [
            {
              "id": "uuid",
              "name": "name1",
              "startDate": "2300-05-01T21:00:00Z",
              "type": "daily",
              "length": 1,
              "participants": [
                {
                  "type": "user",
                  "id": "uuid",
                  "username": "user1@discourse.org"
                },
                {
                  "type": "user",
                  "id": "uuid",
                  "username": "user2@discourse.org"
                }
              ],
              "timeRestriction": {
                "type": "time-of-day",
                "restriction": {
                  "startHour": 21,
                  "endHour": 5,
                  "startMin": 0,
                  "endMin": 0
                }
              }
            }
          ]
        },
        "took": 0.028,
        "requestId": "39dfd8e1-988d-4aad-b7d5-83a4354461c6"
      }.to_json)

      stub_request(:get, "#{schedules_path}/uuid2")
        .with(
          headers: {
            'Authorization'=> "GenieKey #{api_key}"
          }
        )
        .to_return(status: 200, body: {
          "data": {
            "id": "uuid",
            "name": "East",
            "description": "",
            "timezone": "Etc/UTC",
            "enabled": true,
            "ownerTeam": {
              "id": "uuid",
              "name": "someteamname"
            },
            "rotations": [
              {
                "id": "uuid",
                "name": "name1",
                "startDate": "2300-05-01T21:00:00Z",
                "type": "daily",
                "length": 1,
                "participants": [
                  {
                    "type": "user",
                    "id": "uuid",
                    "username": "user3@discourse.org"
                  },
                  {
                    "type": "user",
                    "id": "uuid",
                    "username": "user4@discourse.org"
                  }
                ],
                "timeRestriction": {
                  "type": "time-of-day",
                  "restriction": {
                    "startHour": 0,
                    "endHour": 8,
                    "startMin": 0,
                    "endMin": 0
                  }
                }
              }
            ]
          },
          "took": 0.028,
          "requestId": "39dfd8e1-988d-4aad-b7d5-83a4354461c6"
        }.to_json)
  end

  after do
    $redis.del(described_class.send(:redis_key))
  end

  describe '.users_on_rotation' do
    it 'should return the right user' do
      [
        [
          "2010-01-10 21:00:00 +0000",
          ['user1@discourse.org', 'user2@discourse.org']
        ],
        [
          "2010-01-10 8:00:00 +0000",
          []
        ],
        [
          "2010-01-10 5:00:00 +0000",
          ["user3@discourse.org", "user4@discourse.org"]
        ],
        [
          "2010-01-10 3:00:00 +0000",
          [
            'user1@discourse.org',
            'user2@discourse.org',
            "user3@discourse.org",
            "user4@discourse.org"
          ]
        ]
      ].each do |timestamp, expectation|
        freeze_time Time.parse(timestamp) do
          expect(OpsgenieSchedule.users_on_rotation).to eq(
            expectation
          )
        end
      end
    end
  end
end
