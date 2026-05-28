import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance, query } from "discourse/tests/helpers/qunit-helpers";

function alertData(status, datacenter, id, lastSuppressedAt = null) {
  const data = {
    status,
    identifier: id,
    datacenter,
    starts_at: "2020-07-27T17:26:49.526234411Z",
    ends_at: null,
    external_url: "http://alertmanager.example.com",
    generator_url:
      "https://metrics.sjc1.discourse.cloud/graph?g0.expr=mymetric&g0.tab=1",
    link_url:
      "https://logs.sjc1.discourse.cloud/app/kibana#/discover?_g=()&_a=(columns:!(),filters:!((query:(match:(moby.name:(query:mycontainer,type:phrase))))))",
    last_suppressed_at: lastSuppressedAt,
  };

  if (status === "resolved") {
    data.ends_at = "2020-07-27T17:35:35.870002386Z";
  }

  return data;
}

acceptance(`Alert Receiver`, function (needs) {
  needs.user();
  needs.mobileView();
  needs.settings({
    prometheus_alert_receiver_kibana_regex: "\\/app\\/kibana",
    prometheus_alert_receiver_prometheus_regex: "\\/graph\\?g0\\.expr=",
    discourse_local_dates_enabled: true,
  });

  needs.pretender((server, helper) => {
    const json = cloneJSON(topicFixtures["/t/280/1.json"]);

    json.alert_data = [
      alertData("resolved", "sjc1", "myalert1"),
      alertData("resolved", "sjc1", "myalert2"),
      alertData("suppressed", "sjc1", "myalert3"),
      alertData("stale", "sjc1", "myalert4"),
      alertData("firing", "sjc1", "myalert5"),
      alertData("firing", "sjc2", "myalert6"),
    ];

    server.get("/t/281.json", () => {
      return helper.response(json);
    });
  });

  test("displays all the alerts", async (assert) => {
    await visit("/t/internationalization-localization/281");
    assert
      .dom(".prometheus-alert-receiver")
      .exists({ count: 1 }, "the prometheus data is present");

    const receiver = query(".prometheus-alert-receiver");
    const alertNames = receiver.querySelectorAll("table tr td:first-child");
    assert.deepEqual(
      Array.from(alertNames)
        .map((e) => e.innerText)
        .sort(),
      ["myalert1", "myalert2", "myalert3", "myalert4", "myalert5", "myalert6"],
      "the alerts are all visible"
    );

    assert
      .dom(".prometheus-alert-receiver .external-link a")
      .hasAttribute(
        "href",
        "http://alertmanager.example.com",
        "links the per-dc header to the alertmanager"
      );

    assert
      .dom(
        ".prometheus-alert-receiver [data-alert-status='resolved'] table tr td:first-child a"
      )
      .hasAttribute(
        "href",
        "https://metrics.sjc1.discourse.cloud/graph?g0.expr=mymetric&g0.tab=0&g0.range_input=1127s&g0.end_input=2020-07-27T17%3A40%3A35.870Z",
        "links each alert to its graph, with added timestamp"
      );

    const renderedHref = new URL(
      query(
        ".prometheus-alert-receiver [data-alert-status='resolved'] table tr td:last-child a"
      ).href
    );
    const expectedHref = new URL(
      "https://logs.sjc1.discourse.cloud/app/kibana#/discover?_g=(time:(from:'2020-07-27T17:26:49.526234411Z',mode:absolute,to:'2020-07-27T17:35:35.870002386Z'))&_a=(columns:!(),filters:!((query:(match:(moby.name:(query:mycontainer,type:phrase))))))"
    );

    renderedHref.hash = decodeURIComponent(renderedHref.hash);

    assert.strictEqual(
      renderedHref.toString(),
      expectedHref.toString(),
      "adds a log link, with correct timestamps"
    );

    assert.dom(".discourse-local-date").exists("dates are output");
  });
});

acceptance(`Alert Receiver - previously silenced indicator`, function (needs) {
  needs.user();
  needs.settings({ discourse_local_dates_enabled: true });

  const recent = new Date().toISOString();

  needs.pretender((server, helper) => {
    const json = cloneJSON(topicFixtures["/t/280/1.json"]);

    json.alert_data = [
      // Firing again after a silence lapsed: badge should show.
      alertData("firing", "sjc1", "refired", recent),
      // Currently silenced (shown under "Silenced"): badge must NOT show,
      // even though last_suppressed_at is recent.
      alertData("suppressed", "sjc1", "stillsilenced", recent),
      // Firing but never suppressed: no badge.
      alertData("firing", "sjc1", "neversilenced"),
    ];

    server.get("/t/281.json", () => {
      return helper.response(json);
    });
  });

  test("shows the badge only on firing alerts that were recently suppressed", async (assert) => {
    await visit("/t/internationalization-localization/281");

    assert
      .dom(
        ".prometheus-alert-receiver [data-alert-status='firing'] .alert-was-suppressed"
      )
      .exists(
        { count: 1 },
        "the re-fired alert shows the previously-silenced badge"
      );

    assert
      .dom(
        ".prometheus-alert-receiver [data-alert-status='suppressed'] .alert-was-suppressed"
      )
      .doesNotExist(
        "a currently-silenced alert does not show the previously-silenced badge"
      );
  });
});
