require 'rails_helper'

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  let(:category) { Fabricate(:category) }
  let(:assignee_group) { Fabricate(:group) }
  let(:admin) { Fabricate(:admin) }
  let(:response_body) { response.body }
  let(:parsed_response_body) { JSON.parse(response_body) }
  let(:plugin_name) { DiscoursePrometheusAlertReceiver::PLUGIN_NAME }

  let(:custom_field_key) do
    DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
  end

  describe "#generate_receiver_url" do
    let(:receiver_url) { parsed_response_body['url'] }
    let(:receiver_token) { parsed_response_body['url'].split('/').last }
    let(:receiver) { PluginStore.get(plugin_name, receiver_token) }

    describe 'as an anonymous user' do
      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe 'as a normal user' do
      before do
        sign_in(Fabricate(:user))
      end

      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe 'as an admin user' do
      before do
        sign_in(admin)
      end

      describe 'when category_id param is not given' do
        it "should respond with a bad request error" do
          post "/prometheus/receiver/generate.json"
          expect(response.status).to eq(400)
        end
      end

      it 'should be able to generate a receiver url' do
        freeze_time do
          category = Fabricate(:category)

          post "/prometheus/receiver/generate.json", params: { category_id: category.id }

          expect(response.status).to eq(200)

          body = JSON.parse(response.body)
          receiver = PluginStoreRow.last

          expect(body['success']).to eq('OK')

          expect(body['url']).to eq(
            "#{Discourse.base_url}/prometheus/receiver/#{receiver.key}"
          )

          expect(receiver.value).to eq({
            category_id: category.id,
            created_at: Time.zone.now,
            created_by: admin.id
          }.to_json)
        end
      end

      context "with a category and assignee group" do
        it "should return the right output" do
          post "/prometheus/receiver/generate.json", params: {
            category_id: category.id,
            assignee_group_id: assignee_group.id
          }

          expect(response.status).to eq(200)

          expect(receiver_url).to match(
            %r{\A#{Discourse.base_url}/prometheus/receiver/[0-9a-f]{64}\z}
          )

          expect(receiver["category_id"]).to eq(category.id)
          expect(receiver["assignee_group_id"]).to eq(assignee_group.id)
          expect(receiver["topic_map"]).to eq({})
        end
      end
    end
  end

  describe '#receive_grouped_alerts' do
    let(:token) do
      '557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983'
    end

    before do
      SiteSetting.queue_jobs = false
    end

    describe 'when token is missing or too short' do
      it "should indicate the resource wasn't found" do
        post "/prometheus/receiver/grouped/alerts"
        expect(response.status).to eq(404)

        post "/prometheus/receiver/grouped/alerts/asdasd"
        expect(response.status).to eq(404)
      end
    end

    describe 'when token is invalid' do
      it "should indicate the request was bad" do
        post "/prometheus/receiver/grouped/alerts/#{token}"
        expect(response.status).to eq(400)
      end
    end

    describe 'for a valid token' do
      let(:alert_name) { "JobDown" }

      let(:group_key) do
        "{}/{notify=\"live\"}:{alertname=\"#{alert_name}\", datacenter=\"#{datacenter}\"}"
      end

      let(:topic) { Fabricate(:topic, category: category) }
      let!(:first_post) { Fabricate(:post, topic: topic) }
      let(:topic_map) { { alert_name => topic.id } }
      let(:datacenter) { 'somedatacenter' }
      let(:datacenter2) { 'somedatacenter2' }
      let(:response_sla) { '4hours' }

      before do
        PluginStore.set(plugin_name, token,
          category_id: category.id,
          assignee_group_id: assignee_group.id,
          created_at: Time.zone.now,
          created_by: admin.id,
          topic_map: topic_map
        )
      end

      describe 'for an active alert' do
        before do
          topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2018-07-24T23:25:31.363742333Z",
                'graph_url' => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              },
              {
                'id' => 'somethingnotfunny',
                'starts_at' => "2018-07-24T23:25:31.363742333Z",
                'graph_url' => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              },
              {
                'id' => 'doesnotexists',
                'starts_at' => "2018-07-24T23:25:31.363742333Z",
                'graph_url' => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter2
              }
            ]
          }

          topic.save_custom_fields(true)
        end

        describe 'when payload includes silenced alerts' do
          let(:payload) do
            {
              "status" => "success",
              "externalURL" => "supposed.to.be.a.url",
              "graphURL" => "to.be.a.url",
              "data" => [
                {
                  "labels" => {
                    "alertname" => alert_name,
                    "datacenter" => datacenter
                  },
                  "groupKey" => group_key,
                  "blocks" => [
                    {
                      "routeOpts" => {
                        "receiver" => "somereceiver",
                        "groupBy" => [
                          "alertname",
                          "datacenter"
                        ],
                        "groupWait" => 30000000000,
                        "groupInterval" => 30000000000,
                        "repeatInterval" => 3600000000000
                      },
                      "alerts" => [
                        {
                          "labels" => {
                            "alertname" => alert_name,
                            "datacenter" => "somedatacenter",
                            'id' => 'somethingnotfunny',
                            "instance" => "someinstance",
                            "job" => "somejob",
                            "notify" => "live"
                          },
                          "annotations" => {
                            "description" => "some description",
                            "topic_body" => "some body",
                            "topic_title" => "some title"
                          },
                          "startsAt" => "2018-07-24T23:25:31.363742334Z",
                          "endsAt" => "0001-01-01T00:00:00Z",
                          "generatorURL" => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                          "status" => {
                            "state" => "suppressed",
                            "silencedBy" => [
                              "1de62db1-ac72-48d8-b2d0-7ce0e8acdcb1"
                            ],
                            "inhibitedBy" => nil
                          },
                          "receivers" => nil,
                          "fingerprint" => "09aae3ea59ed5a65"
                        },
                        {
                          "labels" => {
                            "alertname" => alert_name,
                            "datacenter" => "somedatacenter",
                            'id' => 'somethingfunny',
                            "instance" => "someinstance",
                            "job" => "somejob",
                            "notify" => "live"
                          },
                          "annotations" => {
                            "description" => "some description",
                            "topic_body" => "some body",
                            "topic_title" => "some title"
                          },
                          "startsAt" => "2018-07-24T23:25:31.363742334Z",
                          "endsAt" => "0001-01-01T00:00:00Z",
                          "generatorURL" => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                          "status" => {
                            "state" => "suppressed",
                            "silencedBy" => [
                              "1de62db1-ac72-48d8-b2d0-7ce0e8acdcb1"
                            ],
                            "inhibitedBy" => nil
                          },
                          "receivers" => nil,
                          "fingerprint" => "09aae3ea59ed5a65"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          end

          it 'should update the alerts correctly' do
            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            expect(response.status).to eq(200)

            key = DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
            alerts = topic.reload.custom_fields[key]["alerts"]

            [
              ['doesnotexists', 'stale'],
              ['somethingfunny', 'suppressed'],
              ['somethingnotfunny', 'suppressed']
            ].each do |id, status|
              expect(alerts.find { |alert| alert['id'] == id }["status"])
                .to eq(status)
            end

            expect(topic.title).to eq("some title")

            expect(topic.tags.pluck(:name)).to contain_exactly(
              datacenter,
              datacenter2
            )

            raw = first_post.reload.raw

            [
              "# :shushing_face: Silenced Alerts",
              "## #{I18n.t('prom_alert_receiver.post.headers.stale')}",
            ].each do |content|
              expect(raw).to include(content)
            end

            expect(raw).to match(
              /somethingfunny.*date=2018-07-24 time=23:25:31/
            )

            expect(raw).to match(
              /somethingnotfunny.*date=2018-07-24 time=23:25:31/
            )

            expect(raw).to match(
              /doesnotexists.*date=2018-07-24 time=23:25:31/
            )

            expect(
              topic.custom_fields[custom_field_key]['alerts'].first['description']
            ).to eq('some description')
          end

          it 'should not update the topic if nothing has changed' do
            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            messages = MessageBus.track_publish do
              post "/prometheus/receiver/grouped/alerts/#{token}", params: payload
            end

            expect(messages).to eq([])
          end
        end
      end
    end
  end

  describe "#receive" do
    let(:token) do
      '557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983'
    end

    let(:receiver) do
      PluginStore.get(plugin_name, token)
    end

    before do
      SiteSetting.queue_jobs = false
      SiteSetting.tagging_enabled = true
    end

    describe 'when token is missing or too short' do
      it "should indicate the resource wasn't found" do
        post "/prometheus/receiver/"
        expect(response.status).to eq(404)

        post "/prometheus/receiver/asdsa"
        expect(response.status).to eq(404)
      end
    end

    describe 'when token is invalid' do
      it "should indicate the request was bad" do
        post "/prometheus/receiver/#{token}"
        expect(response.status).to eq(400)
      end
    end

    describe "for a valid auto-assigning token" do
      let(:alert_name) { "AnAlert" }
      let(:datacenter) { "some-datacenter" }

      let(:group_key) do
        "{}/{notify=\"live\"}:{alertname=\"#{alert_name}\", datacenter=\"#{datacenter}\"}"
      end

      let(:response_sla) { '4hours' }
      let(:external_url) { "supposed.to.be.a.url" }

      let!(:assignee) do
        Fabricate(:user).tap do |u|
          Fabricate(:group_user, user: u, group: assignee_group)
        end
      end

      let(:payload) do
        {
          "version" => "4",
          "status" => "firing",
          "externalURL" => external_url,
          "groupKey" => group_key,
          "groupLabels" => {
            "foo" => "bar",
            "baz" => "wombat",
          },
          "commonAnnotations" => {
            "topic_body" => "Test topic... test topic... whoop whoop",
            "topic_title" => "Alert investigation required: AnAlert is on the loose",
          },
          "commonLabels" => {
            "alertname" => alert_name,
            "datacenter" => datacenter,
            "response_sla" => response_sla
          },
          "alerts" => [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "firing",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt"     => "2020-01-02T03:04:05.12345678Z",
              "endsAt"       => "0001-01-01T00:00:00Z",
            }
          ],
        }
      end

      before do
        SiteSetting.assign_enabled = true

        PluginStore.set(plugin_name, token,
          category_id: category.id,
          assignee_group_id: assignee_group.id,
          created_at: Time.zone.now,
          created_by: admin.id,
          topic_map: topic_map,
        )
      end

      context "a firing alert on a previously unseen groupKey" do
        let(:topic_map) { {} }

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][alert_name])
        end

        it "should create the right topic" do
          freeze_time Time.now.utc

          messages = MessageBus.track_publish('/alert-receiver') do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to change { Topic.count }.by(1)
          end

          expect(response.status).to eq(200)
          expect(messages.first.data[:firing_alerts_count]).to eq(1)
          expect(topic.category).to eq(category)

          expect(topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
            AlertPostMixin::HIGH_PRIORITY_TAG
          )

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose"
          )

          expect(receiver["topic_map"][alert_name]).to eq(topic.id)

          expect(topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to include(
            "Test topic\.\.\. test topic\.\.\. whoop whoop"
          )

          expect(raw).to include(<<~RAW)
          | [#{datacenter}](#{external_url}) | | |
          | --- | --- | --- |
          RAW

          expect(raw).to match(/somethingfunny.*date=2020-01-02 time=03:04:05/)

          expect(raw).to match(
            /http:\/\/alerts\.example\.com\/graph\?g0\.expr=lolrus.*g0\.tab=0/
          )

          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "an alert with no annotations" do
        let(:topic_map) { {} }

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][alert_name])
        end

        before do
          payload["commonAnnotations"] = {
            "unrelated" => "annotation"
          }
        end

        it "should create the right topic" do
          freeze_time Time.now.utc

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { Topic.count }.by(1)

          expect(topic.title).to eq("foo: bar, baz: wombat")

          expect(topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
            AlertPostMixin::HIGH_PRIORITY_TAG
          )

          raw = topic.posts.first.raw

          expect(raw).to include(
            "## :fire: #{I18n.t('prom_alert_receiver.post.headers.firing')}"
          )

          expect(raw).to include("some description")

          expect(raw).to match(
            /somethingfunny.*date=2020-01-02 time=03:04:05/
          )

          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "a resolving alert for an existing alert" do
        before do
          topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              },
              {
                'id' => 'somethingnotfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              },
            ]
          }

          topic.save_custom_fields(true)

          payload["status"] = "resolved"

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "resolved",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345679Z",
              "endsAt" => "2020-01-02T09:08:07.09876543Z",
            }
          ]
        end

        let(:topic) { Fabricate(:post).topic }
        let(:topic_map) { { alert_name => topic.id } }

        it "updates the existing topic" do
          messages = MessageBus.track_publish('/alert-receiver') do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to_not change { Topic.count }
          end

          topic.reload

          expect(response.status).to eq(200)
          expect(messages.first.data[:firing_alerts_count]).to eq(1)

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose"
          )

          expect(topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
            AlertPostMixin::HIGH_PRIORITY_TAG
          )

          expect(topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'ends_at' => "2020-01-02T09:08:07.09876543Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'resolved',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
              {
                'id' => 'somethingnotfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              }
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to include(
            "## :fire: #{I18n.t("prom_alert_receiver.post.headers.firing")}"
          )

          expect(raw).to match(/somethingnotfunny.*date=2020-01-02 time=03:04:05/)

          expect(raw).to include(
            "## #{I18n.t("prom_alert_receiver.post.headers.history")}"
          )

          expect(raw).to match(/somethingfunny.*date=2020-01-02 time=09:08:07/)
        end
      end

      context "a new firing alert for an existing alert" do
        let(:topic_map) { { alert_name => topic.id } }
        let(:topic) { Fabricate(:post).topic }

        before do
          topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'oldalert',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter,
                'external_url' => external_url
              }
            ]
          }

          topic.save_custom_fields(true)

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "firing",
              "labels" => {
                "id" => "oldalert",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
            },
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "firing",
              "labels" => {
                "id" => "newalert",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-12-31T23:59:59.75645342Z",
            }
          ]
        end

        it "updates the existing topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { Topic.count }

          topic.reload

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose"
          )

          expect(topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
            AlertPostMixin::HIGH_PRIORITY_TAG
          )

          expect(topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "oldalert",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
              {
                'id' => "newalert",
                'starts_at' => "2020-12-31T23:59:59.75645342Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to match(/oldalert.*date=2020-01-02 time=03:04:05/)
          expect(raw).to match(/newalert.*date=2020-12-31 time=23:59:59/)
        end

        describe 'from another datacenter' do
          let(:datacenter2) { "datacenter-2" }
          let(:external_url2) { "supposed.be.a.url.2" }

          before do
            payload["externalURL"] = external_url2
            payload["commonLabels"]["datacenter"] = datacenter2

            payload["alerts"] = [
              {
                "annotations" => {
                  "description" => "some description"
                },
                "status" => "firing",
                "labels" => {
                  "id" => "oldalert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-12-31T23:59:59.75645342Z",
              }
            ]
          end

          it "updates the existing topic correctly" do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to_not change { Topic.count }

            topic.reload

            expect(topic.title).to eq(
              "Alert investigation required: AnAlert is on the loose"
            )

            expect(topic.tags.pluck(:name)).to contain_exactly(
              datacenter,
              datacenter2,
              AlertPostMixin::FIRING_TAG,
              AlertPostMixin::HIGH_PRIORITY_TAG
            )

            expect(topic.custom_fields[custom_field_key]['alerts']).to eq(
              [
                {
                  'id' => "oldalert",
                  'starts_at' => "2020-01-02T03:04:05.12345678Z",
                  'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                  'status' => 'firing',
                  'datacenter' => datacenter,
                  'external_url' => external_url
                },
                {
                  'id' => "oldalert",
                  'starts_at' => "2020-12-31T23:59:59.75645342Z",
                  'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                  'status' => 'firing',
                  'description' => 'some description',
                  'datacenter' => datacenter2,
                  'external_url' => external_url2
                },
              ]
            )

            raw = topic.posts.first.raw

            expect(raw).to include(<<~RAW)
            | [#{datacenter}](#{external_url}) | |
            | --- | --- |
            RAW

            expect(raw).to include(<<~RAW)
            | [#{datacenter2}](#{external_url2}) | | |
            | --- | --- | --- |
            RAW

            expect(raw).to match(
              /oldalert.*date=2020-01-02 time=03:04:05/
            )

            expect(raw).to match(
              /oldalert.*date=2020-12-31 time=23:59:59/
            )
          end
        end
      end

      context "a repeated alert" do
        let(:topic) { Fabricate(:post, raw: 'unchangeable').topic }
        let(:topic_map) { { alert_name => topic.id } }

        before do
          topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'datacenter' => datacenter
              }
            ]
          }

          topic.save_custom_fields(true)

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "firing",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
            },
          ]

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { topic.reload.title }
        end

        it "does not change the existing topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { topic.reload.posts.first.revisions.count }

          expect(topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
            ]
          )
        end

        it 'reassigns the alert if topic has no assignee' do
          TopicAssigner.new(topic, Discourse.system_user).unassign

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { topic.reload.assigned_to_user }

          expect(response.status).to eq(200)
        end
      end

      context "firing alert for a groupkey referencing a closed topic" do
        before do
          closed_topic.update!(
            created_at: DateTime.new(2018, 7, 27, 19, 33, 44)
          )

          closed_topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              }
            ]
          }

          closed_topic.save_custom_fields(true)

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "firing",
              "labels" => {
                "id" => "anotheralert",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-12-31T23:59:59.98765Z",
            },
          ]
        end

        let(:topic_map) { { alert_name => closed_topic.id } }

        let(:closed_topic) do
          topic = Fabricate(:post, raw: 'unchanged').topic
          topic.update!(closed: true)
          topic
        end

        let(:keyed_topic) do
          Topic.find_by(id: receiver["topic_map"][alert_name])
        end

        it "does not change the closed topic's first post" do
          freeze_time Time.now.utc

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { closed_topic.reload.posts.first.revisions.count }

          expect(closed_topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus"
              },
            ]
          )

          expect(keyed_topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose"
          )

          expect(keyed_topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
            AlertPostMixin::HIGH_PRIORITY_TAG
          )

          expect(receiver["topic_map"][alert_name]).to eq(keyed_topic.id)

          expect(keyed_topic.custom_fields[custom_field_key]['alerts']).to eq(
            [
              {
                'id' => "anotheralert",
                'starts_at' => "2020-12-31T23:59:59.98765Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing',
                'description' => 'some description',
                'datacenter' => datacenter,
                'external_url' => external_url
              },
            ]
          )

          expect(keyed_topic.assigned_to_user.id).to eq(assignee.id)

          expect(keyed_topic.posts.first.raw).to match(
            /\[Previous alert topic created\.\]\(http:\/\/test\.localhost\/t\/#{closed_topic.id}\).*date=2018-07-27 time=19:33:44/
          )
        end
      end

      context "resolved alert for an alert" do
        let(:first_post) { Fabricate(:post, raw: 'unchanged') }
        let(:topic) { first_post.topic }
        let(:topic_map) { { alert_name => topic.id } }

        before do
          topic.custom_fields[custom_field_key] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => "resolved",
                'datacenter' => datacenter
              }
            ]
          }

          topic.save_custom_fields(true)

          payload["status"] = "resolved"

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description"
              },
              "status" => "resolved",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
              "endsAt" => "2020-01-02T09:08:07.09876543Z",
            },
          ]
        end

        describe "referencing an open topic" do
          it "should update the first post of the topic" do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to change { first_post.revisions.count }.by(1) &
              change { topic.reload.title }

            expect(topic.title).to eq(
              'Alert investigation required: AnAlert is on the loose'
            )

            expect(topic.tags.pluck(:name)).to contain_exactly(
              datacenter, AlertPostMixin::HIGH_PRIORITY_TAG
            )

            raw = first_post.reload.raw

            expect(raw).to include(
              "## #{I18n.t('prom_alert_receiver.post.headers.history')}"
            )

            expect(raw).to match(
              /somethingfunny.*date=2020-01-02 time=03:04:05.*date=2020-01-02 time=09:08:07/
            )
          end
        end

        describe "referencing a closed topic" do
          before do
            topic.update!(closed: true)
          end

          it "should not do anything" do
            expect do
              expect do
                post "/prometheus/receiver/#{token}", params: payload
              end.to_not change { first_post.reload.revisions.count }
            end.to_not change { Topic.count }
          end
        end
      end

      context "firing alert with a designated assignee" do
        let(:topic_map) { {} }
        let!(:bob) { Fabricate(:user, username: "bobtheangryflower") }

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][alert_name])
        end

        before do
          payload["commonAnnotations"]["topic_assignee"] = "bobtheangryflower"
        end

        it "creates a new topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { Topic.count }.by(1)

          expect(topic.assigned_to_user.id).to eq(bob.id)
        end

        describe 'when prometheus_alert_receiver_enable_assign is false' do
          before do
            SiteSetting.prometheus_alert_receiver_enable_assign = false
          end

          it 'should not assign anyone to the topic' do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to change { Topic.count }.by(1)

            expect(topic.assigned_to_user).to eq(nil)
          end
        end

        describe 'when group_topic_assignee is present in the payload' do
          let(:group) { Fabricate(:group) }

          before do
            group.users << [Fabricate(:user), Fabricate(:user)]
            payload["commonAnnotations"].delete("topic_assignee")
          end

          it 'should assign the topic correctly' do
            [group.name, group.id].each do |id_or_name|
              payload["commonAnnotations"]["group_topic_assignee"] = id_or_name

              expect do
                post "/prometheus/receiver/#{token}", params: payload
              end.to change { Topic.count }.by(1)

              expect(response.status).to eq(200)
              expect(group.users.include?(topic.assigned_to_user)).to eq(true)
              topic.destroy!
            end
          end
        end
      end
    end
  end
end
