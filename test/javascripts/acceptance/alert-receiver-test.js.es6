import { acceptance } from "helpers/qunit-helpers";
import Fixtures from "fixtures/topic";

function alertData(status, datacenter, id) {
  const data = {
    status,
    identifier: id,
    datacenter,
    starts_at: "2020-07-27T17:26:49.526234411Z",
    ends_at: null,
    external_url: "http://alertmanager.example.com",
    graph_url:
      "https://metrics.sjc1.discourse.cloud/graph?g0.expr=mymetric&g0.tab=1",
    logs_url: "http://kibana.example.com/app/kibana"
  };

  if (status === "resolved") {
    data.ends_at = "2020-07-27T17:35:35.870002386Z";
  }

  return data;
}

acceptance("Alert Receiver", {
  loggedIn: true,
  mobileView: true,
  pretend(server, helper) {
    const json = Object.assign({}, Fixtures["/t/280/1.json"]);

    json.alert_data = [
      alertData("resolved", "sjc1", "myalert1"),
      alertData("resolved", "sjc1", "myalert2"),
      alertData("suppressed", "sjc1", "myalert3"),
      alertData("stale", "sjc1", "myalert4"),
      alertData("firing", "sjc1", "myalert5"),
      alertData("firing", "sjc2", "myalert6")
    ];

    server.get("/t/281.json", () => {
      return helper.response(json);
    });
  }
});

QUnit.test("displays all the alerts", async assert => {
  await visit("/t/internationalization-localization/281");
  assert.ok(
    exists(".prometheus-alert-receiver"),
    "the prometheus data is visible"
  );

  const alertNames = find(".prometheus-alert-receiver")[0].querySelectorAll(
    "table tr td:first-child"
  );
  assert.deepEqual(
    Array.from(alertNames)
      .map(e => e.innerText)
      .sort(),
    ["myalert1", "myalert2", "myalert3", "myalert4", "myalert5", "myalert6"],
    "the alerts are all visible"
  );

  assert.equal(
    find(".prometheus-alert-receiver table thead th:first-child a").attr(
      "href"
    ),
    "http://alertmanager.example.com",
    "links the per-dc header to the alertmanager"
  );

  assert.equal(
    find(
      ".prometheus-alert-receiver [data-alert-status='resolved'] table tr td:first-child a"
    ).attr("href"),
    "https://metrics.sjc1.discourse.cloud/graph?g0.expr=mymetric&g0.tab=0&g0.range_input=1127s&g0.end_input=2020-07-27T17%3A40%3A35.870Z",
    "links each alert to its graph, with added timestamp"
  );

  assert.equal(
    find(
      ".prometheus-alert-receiver [data-alert-status='resolved'] table tr td:last-child a"
    ).attr("href"),
    "http://kibana.example.com/app/kibana#/discover?_g=(time:(from:'2020-07-27T17:26:49.526234411Z',mode:absolute,to:'2020-07-27T17:35:35.870002386Z'))",
    "adds a log link, with correct timestamps"
  );
});
