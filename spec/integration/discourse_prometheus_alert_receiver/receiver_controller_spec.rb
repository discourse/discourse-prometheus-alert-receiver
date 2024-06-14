# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  let(:category) { Fabricate(:category) }
  let(:assignee_group) { Fabricate(:group) }
  let(:admin) { Fabricate(:admin) }
  let(:response_body) { response.body }
  let(:parsed_response_body) { JSON.parse(response_body) }
  let(:plugin_name) { DiscoursePrometheusAlertReceiver::PLUGIN_NAME }

  before { SiteSetting.assign_allowed_on_groups = assignee_group.id.to_s }

  describe "#generate_receiver_url" do
    let(:receiver_url) { parsed_response_body["url"] }
    let(:receiver_token) { parsed_response_body["url"].split("/").last }
    let(:receiver) { PluginStore.get(plugin_name, receiver_token) }

    describe "as an anonymous user" do
      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe "as a normal user" do
      before { sign_in(Fabricate(:user)) }

      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe "as an admin user" do
      before { sign_in(admin) }

      describe "when category_id param is not given" do
        it "should respond with a bad request error" do
          post "/prometheus/receiver/generate.json"
          expect(response.status).to eq(400)
        end
      end

      it "should be able to generate a receiver url" do
        freeze_time do
          category = Fabricate(:category)

          post "/prometheus/receiver/generate.json", params: { category_id: category.id }

          expect(response.status).to eq(200)

          body = JSON.parse(response.body)
          receiver = PluginStoreRow.last

          expect(body["success"]).to eq("OK")

          expect(body["url"]).to eq("#{Discourse.base_url}/prometheus/receiver/#{receiver.key}")

          expect(receiver.value).to eq(
            {
              category_id: category.id,
              created_at: Time.zone.now,
              created_by: admin.id,
              topic_map: {
              },
            }.to_json,
          )
        end
      end

      context "with a category and assignee group" do
        it "should return the right output" do
          post "/prometheus/receiver/generate.json",
               params: {
                 category_id: category.id,
                 assignee_group_id: assignee_group.id,
               }

          expect(response.status).to eq(200)

          expect(receiver_url).to match(
            %r{\A#{Discourse.base_url}/prometheus/receiver/[0-9a-f]{64}\z},
          )

          expect(receiver["category_id"]).to eq(category.id)
          expect(receiver["assignee_group_id"]).to eq(assignee_group.id)
          expect(receiver["topic_map"]).to eq({})
        end
      end
    end
  end

  describe "#receive_grouped_alerts" do
    let(:token) { "557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983" }

    before do
      Jobs.run_immediately!
      SiteSetting.tagging_enabled = true
    end

    describe "when token is missing or too short" do
      it "should indicate the resource wasn't found" do
        post "/prometheus/receiver/grouped/alerts"
        expect(response.status).to eq(404)

        post "/prometheus/receiver/grouped/alerts/asdasd"
        expect(response.status).to eq(404)
      end
    end

    describe "when token is invalid" do
      it "should indicate the request was bad" do
        post "/prometheus/receiver/grouped/alerts/#{token}"
        expect(response.status).to eq(400)
      end
    end

    describe "for a valid token" do
      let(:alert_name) { "JobDown" }

      let(:group_key) do
        "{}/{notify=\"live\"}:{alertname=\"#{alert_name}\", datacenter=\"#{datacenter}\"}"
      end

      let(:topic) { Fabricate(:topic, category: category) }
      let!(:first_post) { Fabricate(:post, topic: topic) }
      let(:topic_map) { { alert_name => topic.id } }
      let(:datacenter) { "somedatacenter" }
      let(:datacenter2) { "somedatacenter2" }
      let(:response_sla) { "4hours" }

      before do
        PluginStore.set(
          plugin_name,
          token,
          category_id: category.id,
          assignee_group_id: assignee_group.id,
          created_at: Time.zone.now,
          created_by: admin.id,
          topic_map: topic_map,
        )
      end

      describe "for an active alert" do
        before do
          [
            {
              identifier: "somethingfunny",
              starts_at: "2018-07-24T23:25:31.363742333Z",
              generator_url: "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
              status: "firing",
              datacenter: datacenter,
              external_url: "http://alerts.example.com",
            },
            {
              identifier: "somethingnotfunny",
              starts_at: "2018-07-24T23:25:31.363742333Z",
              generator_url: "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
              status: "firing",
              datacenter: datacenter,
              external_url: "http://alerts.example.com",
            },
            {
              identifier: "doesnotexists",
              starts_at: "2018-07-24T23:25:31.363742333Z",
              generator_url: "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
              status: "firing",
              datacenter: datacenter,
              external_url: "http://alerts.example.com",
            },
          ].each { |a| topic.alert_receiver_alerts.create!(**a) }

          topic.custom_fields[
            DiscoursePrometheusAlertReceiver::TOPIC_BASE_TITLE_CUSTOM_FIELD
          ] = "some title"

          topic.save_custom_fields(true)
        end

        describe "when payload includes silenced alerts in the new format" do
          let(:payload) do
            {
              "status" => "success",
              "externalURL" => "http://alerts.example.com",
              "graphURL" => "to.be.a.url",
              "data" => [
                {
                  "labels" => {
                    "alertname" => alert_name,
                    "datacenter" => "somedatacenter",
                    "id" => "somethingnotfunny",
                    "instance" => "someinstance",
                    "job" => "somejob",
                    "notify" => "live",
                  },
                  "annotations" => {
                    "description" => "some description",
                    "topic_body" => "some body",
                    "topic_title" => "some title",
                  },
                  "startsAt" => "2018-07-24T23:25:31.363742334Z",
                  "endsAt" => "0001-01-01T00:00:00Z",
                  "generatorURL" => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                  "status" => {
                    "state" => "suppressed",
                    "silencedBy" => ["1de62db1-ac72-48d8-b2d0-7ce0e8acdcb1"],
                    "inhibitedBy" => nil,
                  },
                  "receivers" => nil,
                  "fingerprint" => "09aae3ea59ed5a65",
                },
                {
                  "labels" => {
                    "alertname" => alert_name,
                    "datacenter" => "somedatacenter",
                    "id" => "somethingfunny",
                    "instance" => "someinstance",
                    "job" => "somejob",
                    "notify" => "live",
                  },
                  "annotations" => {
                    "description" => "some description",
                    "topic_body" => "some body",
                    "topic_title" => "some title",
                  },
                  "startsAt" => "2018-07-24T23:25:31.363742334Z",
                  "endsAt" => "0001-01-01T00:00:00Z",
                  "generatorURL" => "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
                  "status" => {
                    "state" => "suppressed",
                    "silencedBy" => ["1de62db1-ac72-48d8-b2d0-7ce0e8acdcb1"],
                    "inhibitedBy" => nil,
                  },
                  "receivers" => nil,
                  "fingerprint" => "09aae3ea59ed5a65",
                },
              ],
            }
          end

          it "should update the alerts correctly" do
            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            expect(response.status).to eq(200)

            alerts = topic.reload.alert_receiver_alerts.to_a

            [
              %w[doesnotexists stale],
              %w[somethingfunny suppressed],
              %w[somethingnotfunny suppressed],
            ].each do |id, status|
              expect(alerts.find { |alert| alert.identifier == id }.status).to eq(status)
            end

            expect(topic.title).to eq("some title")

            expect(topic.tags.pluck(:name)).to contain_exactly(datacenter)

            expect(
              topic.alert_receiver_alerts.find_by(identifier: "somethingfunny").description,
            ).to eq("some description")
          end

          it "should restore alerts when they are unsilenced" do
            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload
            expect(
              topic.reload.alert_receiver_alerts.find_by(identifier: "somethingnotfunny").status,
            ).to eq("suppressed")

            payload["data"].find { |a| a["labels"]["id"] == "somethingnotfunny" }["status"][
              "state"
            ] = "active"

            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            expect(
              topic.reload.alert_receiver_alerts.find_by(identifier: "somethingnotfunny").status,
            ).to eq("firing")
          end

          it "should not update the topic if nothing has changed" do
            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            messages =
              MessageBus.track_publish do
                post "/prometheus/receiver/grouped/alerts/#{token}", params: payload
              end

            expect(messages).to eq([])
          end

          it "should not get confused by alerts with the same id" do
            topic2 = Fabricate(:topic, category: category)
            topic2.alert_receiver_alerts.create!(
              identifier: "somethingfunny",
              starts_at: "2018-07-24T23:25:31.363742333Z",
              generator_url: "http://supposed.to.be.a.url/graph?g0.expr=lolrus",
              status: "firing",
              datacenter: datacenter,
              external_url: "http://alerts.example.com",
            )

            topic2.custom_fields[
              DiscoursePrometheusAlertReceiver::TOPIC_BASE_TITLE_CUSTOM_FIELD
            ] = "some title"
            topic2.save_custom_fields(true)

            PluginStore.set(
              plugin_name,
              token,
              PluginStore
                .get(plugin_name, token)
                .tap { |data| data["topic_map"]["OtherAlertName"] = topic2.id },
            )

            # JobDown/somethingfunny should be firing
            payload["data"].find { |a| a["labels"]["id"] == "somethingfunny" }["status"][
              "state"
            ] = "active"

            # Create new alert OtherAlertName/somethingfunny, which is silenced
            payload["data"].append(
              JSON
                .parse(payload["data"].find { |a| a["labels"]["id"] == "somethingfunny" }.to_json)
                .tap do |a|
                  a["labels"]["alertname"] = "OtherAlertName"
                  a["status"]["state"] = "suppressed"
                end,
            )

            post "/prometheus/receiver/grouped/alerts/#{token}", params: payload

            # First topic should be unaffected
            expect(
              topic.reload.alert_receiver_alerts.find_by(identifier: "somethingfunny").status,
            ).to eq("firing")

            # Second topic should be updated
            expect(
              topic2.reload.alert_receiver_alerts.find_by(identifier: "somethingfunny").status,
            ).to eq("suppressed")
          end
        end
      end
    end
  end

  describe "#receive" do
    let(:token) { "557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983" }

    let(:receiver) { PluginStore.get(plugin_name, token) }

    before do
      Jobs.run_immediately!
      SiteSetting.tagging_enabled = true
    end

    describe "when token is missing or too short" do
      it "should indicate the resource wasn't found" do
        post "/prometheus/receiver/"
        expect(response.status).to eq(404)

        post "/prometheus/receiver/asdsa"
        expect(response.status).to eq(404)
      end
    end

    describe "when token is invalid" do
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

      let(:response_sla) { "4hours" }
      let(:external_url) { "supposed.to.be.a.url" }

      let!(:assignee) do
        Fabricate(:user).tap { |u| Fabricate(:group_user, user: u, group: assignee_group) }
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
            "response_sla" => response_sla,
          },
          "alerts" => [
            {
              "annotations" => {
                "description" => "some description",
              },
              "status" => "firing",
              "labels" => {
                "id" => "somethingfunny",
                "alertname" => alert_name,
                "datacenter" => datacenter,
                "response_sla" => response_sla,
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
              "endsAt" => "0001-01-01T00:00:00Z",
            },
          ],
        }
      end

      before do
        SiteSetting.assign_enabled = true

        PluginStore.set(
          plugin_name,
          token,
          category_id: category.id,
          assignee_group_id: assignee_group.id,
          created_at: Time.zone.now,
          created_by: admin.id,
          topic_map: topic_map,
        )
      end

      context "with a firing alert on a previously unseen groupKey" do
        let(:topic_map) { {} }

        let(:topic) { Topic.find_by(id: receiver["topic_map"][alert_name]) }

        it "should create the right topic" do
          freeze_time Time.now.utc

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            Topic.count
          }.by(1)

          expect(response.status).to eq(200)
          expect(topic.category).to eq(category)

          expect(topic.tags.pluck(:name)).to contain_exactly(datacenter, AlertPostMixin::FIRING_TAG)

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose (1 firing)",
          )

          expect(receiver["topic_map"][alert_name]).to eq(topic.id)

          expect(topic.alert_receiver_alerts.count).to eq(1)

          a = topic.alert_receiver_alerts.first
          expect(a.identifier).to eq("somethingfunny")
          expect(a.starts_at).to eq_time(DateTime.parse("2020-01-02T03:04:05.12345678Z"))
          expect(a.generator_url).to eq("http://alerts.example.com/graph?g0.expr=lolrus")
          expect(a.status).to eq("firing")
          expect(a.description).to eq("some description")
          expect(a.datacenter).to eq(datacenter)
          expect(a.external_url).to eq(external_url)

          raw = topic.posts.first.raw

          expect(raw).to include("Test topic\.\.\. test topic\.\.\. whoop whoop")
        end
      end

      context "with an alert with no annotations" do
        let(:topic_map) { {} }

        let(:topic) { Topic.find_by(id: receiver["topic_map"][alert_name]) }

        before { payload["commonAnnotations"] = { "unrelated" => "annotation" } }

        it "should create the right topic" do
          freeze_time Time.now.utc

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            Topic.count
          }.by(1)

          expect(topic.title).to eq("foo: bar, baz: wombat (1 firing)")

          expect(topic.tags.pluck(:name)).to contain_exactly(datacenter, AlertPostMixin::FIRING_TAG)
        end
      end

      context "with an alert with no identifier" do
        let(:topic) { Fabricate(:post).topic }
        let(:topic_map) { { alert_name => topic.id } }

        before { payload["alerts"].first["labels"].delete("id") }

        it "should update the topic" do
          freeze_time Time.now.utc

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            AlertReceiverAlert.count
          }.by(1)

          expect(topic.alert_receiver_alerts.first.identifier).to eq("")
        end
      end

      context "with an alert with topic_tags" do
        let(:topic) { Fabricate(:post).topic }
        let(:topic_map) { { alert_name => topic.id } }

        before { payload["commonAnnotations"]["topic_tags"] = "tag1,tag2" }

        it "should update the topic" do
          freeze_time Time.now.utc

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            AlertReceiverAlert.count
          }.by(1)

          expect(topic.tags.pluck(:name)).to include("tag1", "tag2")
        end
      end

      context "with a resolving alert for a closed alert" do
        before do
          topic.alert_receiver_alerts.create!(
            identifier: "somethingfunny",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            link_url: "http://logs.example.com/app",
            status: "firing",
            datacenter: datacenter,
            external_url: "http://alerts.example.com",
          )
          topic.alert_receiver_alerts.create!(
            identifier: "somethingnotfunny",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            link_url: "http://logs.example.com/app",
            status: "firing",
            datacenter: datacenter,
            external_url: "http://alerts.example.com",
          )

          topic.update!(closed: true)

          payload["status"] = "resolved"

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description",
              },
              "status" => "resolved",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345679Z",
              "endsAt" => "2020-01-02T09:08:07.09876543Z",
            },
          ]
        end

        let(:topic) { Fabricate(:post).topic }
        let(:topic_map) { { alert_name => topic.id } }

        it "does not change existing topic" do
          messages =
            MessageBus.track_publish("/alert-receiver") do
              expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
                Topic.count
              }
            end

          topic.reload

          expect(response.status).to eq(200)
          expect(messages.count).to eq(0)

          expect(topic.alert_receiver_alerts.firing.count).to eq(2)
        end
      end

      context "with a new firing alert for an existing alert" do
        let(:topic_map) { { alert_name => topic.id } }
        let(:topic) { Fabricate(:post).topic }

        before do
          topic.alert_receiver_alerts.create!(
            identifier: "oldalert",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            status: "firing",
            datacenter: datacenter,
            external_url: external_url,
          )

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description",
              },
              "status" => "firing",
              "labels" => {
                "id" => "oldalert",
                "datacenter" => datacenter,
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
            },
            {
              "annotations" => {
                "description" => "some description",
              },
              "status" => "firing",
              "labels" => {
                "id" => "newalert",
                "datacenter" => datacenter,
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-12-31T23:59:59.75645342Z",
            },
          ]
        end

        it "updates the existing topic" do
          expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
            Topic.count
          }

          topic.reload

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose (2 firing)",
          )

          expect(topic.tags.pluck(:name)).to contain_exactly(datacenter, AlertPostMixin::FIRING_TAG)

          expect(topic.alert_receiver_alerts.pluck(:identifier, :status)).to contain_exactly(
            %w[oldalert firing],
            %w[newalert firing],
          )
        end

        it "bumps the existing topic correctly" do
          freeze_time(1.hour.from_now) do
            expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
              topic.reload.bumped_at
            }

            expect(topic.reload.title).to eq(
              "Alert investigation required: AnAlert is on the loose (2 firing)",
            )
          end

          freeze_time(2.hours.from_now) do
            payload["alerts"][0]["status"] = "resolved"
            expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
              topic.reload.bumped_at
            }

            expect(topic.reload.title).to eq(
              "Alert investigation required: AnAlert is on the loose (1 firing)",
            )
          end

          freeze_time(3.hours.from_now) do
            payload["alerts"][1]["status"] = "resolved"
            expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
              topic.reload.bumped_at
            }

            expect(topic.reload.title).to eq(
              "Alert investigation required: AnAlert is on the loose",
            )
          end
        end

        describe "from another datacenter" do
          let(:datacenter2) { "datacenter-2" }
          let(:external_url2) { "supposed.be.a.url.2" }

          before do
            payload["externalURL"] = external_url2
            payload["commonLabels"]["datacenter"] = datacenter2

            payload["alerts"] = [
              {
                "annotations" => {
                  "description" => "some description",
                },
                "status" => "firing",
                "labels" => {
                  "id" => "oldalert",
                  "datacenter" => datacenter2,
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-12-31T23:59:59.75645342Z",
              },
            ]
          end

          it "updates the existing topic correctly" do
            expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
              Topic.count
            }

            topic.reload

            expect(topic.title).to eq(
              "Alert investigation required: AnAlert is on the loose (2 firing)",
            )

            expect(topic.tags.pluck(:name)).to contain_exactly(
              datacenter,
              datacenter2,
              AlertPostMixin::FIRING_TAG,
            )

            expect(
              topic.alert_receiver_alerts.pluck(:identifier, :datacenter, :external_url, :status),
            ).to contain_exactly(
              %w[oldalert some-datacenter supposed.to.be.a.url firing],
              %w[oldalert datacenter-2 supposed.be.a.url.2 firing],
            )
          end
        end
      end

      context "with a repeated alert" do
        let(:topic) { Fabricate(:post, raw: "unchangeable").topic }
        let(:topic_map) { { alert_name => topic.id } }

        before do
          topic.alert_receiver_alerts.create!(
            identifier: "somethingfunny",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            status: "firing",
            datacenter: datacenter,
            external_url: external_url,
          )

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description",
              },
              "status" => "firing",
              "labels" => {
                "id" => "somethingfunny",
              },
              "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
              "startsAt" => "2020-01-02T03:04:05.12345678Z",
            },
          ]

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            topic.reload.title
          }
        end

        it "does not change the existing topic" do
          expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
            topic.reload.alert_receiver_alerts.pluck(AlertReceiverAlert.column_names)
          }

          expect(topic.alert_receiver_alerts.pluck(:identifier, :status)).to eq(
            [%w[somethingfunny firing]],
          )
        end

        it "does not change the existing topic, even if the start time is different" do
          # Can happen in a clustered alertmanager setup
          payload["alerts"].first["startsAt"] = "2020-01-02T03:05:05.87654321Z"

          expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
            topic.reload.alert_receiver_alerts.pluck(AlertReceiverAlert.column_names)
          }
        end
      end

      context "with a firing alert for a groupkey referencing a closed topic" do
        before do
          closed_topic.update!(created_at: DateTime.new(2018, 7, 27, 19, 33, 44))

          closed_topic.alert_receiver_alerts.create!(
            identifier: "somethingfunny",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            external_url: external_url,
            status: "firing",
          )

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description",
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
          topic = Fabricate(:post, raw: "unchanged").topic
          topic.update!(closed: true)
          topic
        end

        let(:keyed_topic) { Topic.find_by(id: receiver["topic_map"][alert_name]) }

        it "does not change the closed topic's first post" do
          freeze_time Time.now.utc

          expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
            closed_topic.reload.alert_receiver_alerts.pluck(AlertReceiverAlert.column_names)
          }

          expect(keyed_topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose (1 firing)",
          )

          expect(keyed_topic.tags.pluck(:name)).to contain_exactly(
            datacenter,
            AlertPostMixin::FIRING_TAG,
          )

          expect(receiver["topic_map"][alert_name]).to eq(keyed_topic.id)

          expect(keyed_topic.alert_receiver_alerts.pluck(:identifier, :status)).to eq(
            [%w[anotheralert firing]],
          )

          expect(keyed_topic.posts.first.raw).to match(
            %r{\[Previous alert\]\(http://test\.localhost/t/#{closed_topic.id}\).*date=2018-07-27 time=19:33:44},
          )
        end
      end

      context "with a resolved alert for an alert" do
        let(:first_post) { Fabricate(:post, raw: "unchanged") }
        let(:topic) { first_post.topic }
        let(:topic_map) { { alert_name => topic.id } }

        before do
          topic.alert_receiver_alerts.create!(
            identifier: "somethingfunny",
            starts_at: "2020-01-02T03:04:05.12345678Z",
            generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
            status: "firing",
            datacenter: datacenter,
            external_url: external_url,
          )

          payload["status"] = "resolved"

          payload["alerts"] = [
            {
              "annotations" => {
                "description" => "some description",
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
            expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
              topic.reload.alert_receiver_alerts.pluck(AlertReceiverAlert.column_names)
            } & change { topic.reload.title }

            expect(topic.title).to eq("Alert investigation required: AnAlert is on the loose")

            expect(topic.tags.pluck(:name)).to contain_exactly(datacenter)

            alert = topic.alert_receiver_alerts.first
            expect(alert.status).to eq("resolved")
            expect(alert.ends_at).to eq_time(DateTime.parse("2020-01-02T09:08:07.09876543Z"))
          end
        end

        describe "referencing a closed topic" do
          before { topic.update!(closed: true) }

          it "should not do anything" do
            expect do
              expect do post "/prometheus/receiver/#{token}", params: payload end.to_not change {
                first_post.reload.revisions.count
              }
            end.to_not change { Topic.count }
          end
        end
      end

      context "with a firing alert with a designated assignee" do
        let(:topic_map) { {} }
        let!(:bob) { Fabricate(:user, username: "bobtheangryflower") }

        let(:topic) { Topic.find_by(id: receiver["topic_map"][alert_name]) }

        before { assignee_group.add(bob) }

        it "creates a new topic with the right assignment when `commonAnnotations.topic_assignee` field is present in the payload" do
          payload["commonAnnotations"]["topic_assignee"] = "bobtheangryflower"

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            Topic.count
          }.by(1)

          expect(topic.assigned_to).to eq(bob)
        end

        it "creates a new topic with the right assignment when `commonAnnotations.topic_group_assignee` field is present in the payload" do
          assignee_group.update!(assignable_level: Group::ALIAS_LEVELS[:only_admins])

          payload["commonAnnotations"]["topic_group_assignee"] = assignee_group.name

          expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
            Topic.count
          }.by(1)

          expect(response.status).to eq(200)
          expect(topic.assigned_to).to eq(assignee_group)
        end

        describe "when `prometheus_alert_receiver_enable_assign` site setting is false" do
          before { SiteSetting.prometheus_alert_receiver_enable_assign = false }

          it "should not assign anyone to the topic" do
            expect do post "/prometheus/receiver/#{token}", params: payload end.to change {
              Topic.count
            }.by(1)

            expect(topic.assigned_to).to eq(nil)
          end
        end
      end
    end
  end
end
