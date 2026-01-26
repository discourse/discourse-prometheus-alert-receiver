# frozen_string_literal: true

RSpec.describe AlertReceiverAlert do
  fab!(:topic1, :topic)
  fab!(:topic2, :topic)

  def alert(args)
    dc = args[:datacenter] || "dc"
    {
      topic_id: topic1.id,
      external_url: "alerts.#{dc}.example.com",
      datacenter: dc,
      identifier: "myid",
      status: "firing",
      starts_at: "2020-08-07T10:15:30.8467664Z",
      ends_at: nil,
    }.merge(args)
  end

  it "can add firing alerts and resolve/suppress them" do
    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1"),
        alert(identifier: "myid2"),
        alert(identifier: "myid1", datacenter: "dc2"),
        alert(identifier: "myid2", datacenter: "dc2"),
      ],
    )

    expect(AlertReceiverAlert.count).to eq(4)
    expect(AlertReceiverAlert.firing.count).to eq(4)

    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1", status: "suppressed"),
        alert(identifier: "myid2", status: "resolved"),
        alert(identifier: "myid1", datacenter: "dc2", status: "suppressed"),
        alert(identifier: "myid2", datacenter: "dc2", status: "resolved"),
      ],
    )

    expect(AlertReceiverAlert.count).to eq(4)
    expect(AlertReceiverAlert.firing.count).to eq(0)
  end

  it "does not insert suppressed alerts" do
    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1", status: "suppressed"),
        alert(identifier: "myid2", status: "firing"),
        alert(identifier: "myid1", datacenter: "dc2", status: "suppressed"),
        alert(identifier: "myid2", datacenter: "dc2", status: "firing"),
      ],
    )

    expect(AlertReceiverAlert.count).to eq(2)
    expect(AlertReceiverAlert.firing.count).to eq(2)
  end

  it "can return modified topic ids" do
    topic_ids =
      AlertReceiverAlert.update_alerts(
        [
          alert(identifier: "myid1"),
          alert(identifier: "myid2"),
          alert(identifier: "myid1", datacenter: "dc2"),
          alert(identifier: "myid2", datacenter: "dc2"),
        ],
      )
    expect(topic_ids).to eq([topic1.id])

    topic_ids =
      AlertReceiverAlert.update_alerts(
        [
          alert(identifier: "myid1"),
          alert(identifier: "myid2"),
          alert(identifier: "myid1", datacenter: "dc2"),
          alert(identifier: "myid2", datacenter: "dc2"),
        ],
      )
    expect(topic_ids).to eq([])

    topic_ids =
      AlertReceiverAlert.update_alerts(
        [
          alert(identifier: "myid1"),
          alert(identifier: "myid2"),
          alert(identifier: "myid1", datacenter: "dc2", description: "mydescription"),
          alert(identifier: "myid2", datacenter: "dc2"),
        ],
      )
    expect(topic_ids).to eq([topic1.id])

    topic_ids =
      AlertReceiverAlert.update_alerts(
        [
          alert(identifier: "myid1", status: "suppressed"),
          alert(identifier: "myid2"),
          alert(identifier: "myid1", datacenter: "dc2", description: "mydescription"),
          alert(identifier: "myid2", datacenter: "dc2"),
        ],
      )
    expect(topic_ids).to eq([topic1.id])

    topic_ids =
      AlertReceiverAlert.update_alerts(
        [
          alert(identifier: "myid1", status: "suppressed"),
          alert(identifier: "myid2"),
          alert(identifier: "myid1", datacenter: "dc2", description: "mydescription"),
          alert(identifier: "myid2", datacenter: "dc2", status: "resolved"),
        ],
      )
    expect(topic_ids).to eq([topic1.id])
  end

  it "can mark stale correctly" do
    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1"),
        alert(identifier: "myid2"),
        alert(identifier: "myid1", datacenter: "dc2"),
        alert(identifier: "myid2", datacenter: "dc2"),
      ],
    )

    expect(AlertReceiverAlert.count).to eq(4)
    expect(AlertReceiverAlert.firing.count).to eq(4)

    AlertReceiverAlert.update_alerts(
      [alert(identifier: "myid2")],
      mark_stale_external_url: "alerts.dc.example.com",
    )

    expect(AlertReceiverAlert.count).to eq(4)
    expect(AlertReceiverAlert.firing.count).to eq(3)
    expect(AlertReceiverAlert.stale.count).to eq(1)
  end

  it "discards duplicate alerts before inserting" do
    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1"),
        alert(identifier: "myid1"),
        alert(identifier: "myid2"),
        alert(identifier: "myid2"),
      ],
    )

    expect(AlertReceiverAlert.count).to eq(2)
    expect(AlertReceiverAlert.firing.count).to eq(2)
  end

  it "never updates status in closed topics" do
    AlertReceiverAlert.update_alerts(
      [alert(identifier: "myid1"), alert(identifier: "myid2"), alert(identifier: "myid3")],
    )

    expect(AlertReceiverAlert.count).to eq(3)
    expect(AlertReceiverAlert.firing.count).to eq(3)

    topic1.update!(closed: true)

    AlertReceiverAlert.update_alerts(
      [
        alert(identifier: "myid1", status: "resolved"),
        alert(identifier: "myid2", status: "suppressed"),
        # myid3 stale
      ],
    )

    expect(AlertReceiverAlert.count).to eq(3)
    expect(AlertReceiverAlert.firing.count).to eq(3)
  end
end
