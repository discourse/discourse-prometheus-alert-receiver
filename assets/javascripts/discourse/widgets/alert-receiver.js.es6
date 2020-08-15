import I18n from "I18n";
import { createWidget } from "discourse/widgets/widget";
import hbs from "discourse/widgets/hbs-compiler";
import RawHtml from "discourse/widgets/raw-html";
import { h } from "virtual-dom";

const STATUS_NAMES = ["firing", "suppressed", "stale", "resolved"];
const STATUS_EMOJIS = {
  firing: "fire",
  suppressed: "shushing_face"
};

const COLLAPSE_THRESHOLD = 30;

createWidget("alert-receiver-data", {
  tagName: "div",
  buildClasses() {
    return "cooked prometheus-alert-receiver";
  },

  html(attrs) {
    const groupedByStatus = {};
    const statusCounts = {};

    attrs.alerts.forEach(a => {
      if (!groupedByStatus[a.status]) {
        groupedByStatus[a.status] = {};
        statusCounts[a.status] = 0;
      }
      const groupedByDc = groupedByStatus[a.status];
      if (!groupedByDc[a.datacenter]) {
        groupedByDc[a.datacenter] = [];
      }
      groupedByDc[a.datacenter].push(a);
      statusCounts[a.status] += 1;
    });

    const content = [];

    STATUS_NAMES.forEach(statusName => {
      const groupedByDc = groupedByStatus[statusName];
      if (!groupedByDc) return;

      const headerContent = [];
      if (STATUS_EMOJIS[statusName]) {
        headerContent.push(
          this.attach("emoji", { name: STATUS_EMOJIS[statusName] })
        );
        headerContent.push(" ");
      }
      headerContent.push(I18n.t(`prom_alert_receiver.headers.${statusName}`));
      content.push(h("h2", {}, headerContent));

      const collapsed = statusCounts[statusName] > COLLAPSE_THRESHOLD;

      Object.entries(groupedByDc).forEach(([dcName, alerts]) => {
        const table = this.attach("alert-receiver-table", {
          status: statusName,
          alerts: alerts,
          heading: dcName,
          headingLink: alerts[0].external_url
        });
        let toAppend = table;

        if (collapsed) {
          toAppend = this.attach("alert-receiver-collapsible-table", {
            alerts: alerts,
            heading: dcName,
            contents: () => {
              return table;
            }
          });
        }

        content.push(toAppend);
      });
    });

    return content;
  }
});

createWidget("alert-receiver-date", {
  tagName: "span.alert-receiver-date",
  html(attrs) {
    if (!attrs.timestamp) return;

    const splitTimestamp = attrs.timestamp.split("T");
    if (!splitTimestamp.length === 2) return;

    const date = splitTimestamp[0];
    const time = splitTimestamp[1];

    const dateElement = document.createElement("span");
    dateElement.className = "discourse-local-date";

    const data = dateElement.dataset;

    if (attrs.hideDate) {
      data.format = "HH:mm";
    } else {
      data.format = "YYYY-MM-DD HH:mm";
    }

    data.displayedTimezone = "UTC";
    data.date = date;
    data.time = time;
    data.timezone = "UTC";

    dateElement.textContent = attrs.timestamp;

    if ($().applyLocalDates) $(dateElement).applyLocalDates();

    return new RawHtml({ html: dateElement.outerHTML });
  }
});

createWidget("alert-receiver-date-range", {
  tagName: "span",
  html(attrs) {
    const content = [];
    if (!attrs.startsAt) return;

    if (!attrs.endsAt) {
      content.push("active since ");
    }

    content.push(
      this.attach("alert-receiver-date", { timestamp: attrs.startsAt })
    );

    if (attrs.endsAt) {
      content.push(" to ");
      const startDate = attrs.startsAt.split("T")[0];
      const endDate = attrs.endsAt.split("T")[0];

      const hideDate = startDate === endDate;

      content.push(
        this.attach("alert-receiver-date", {
          timestamp: attrs.endsAt,
          hideDate
        })
      );
    }

    return content;
  }
});

createWidget("alert-receiver-row", {
  tagName: "tr",

  transform(attrs) {
    return {
      logsUrl: this.buildLogsUrl(attrs),
      graphUrl: this.buildGraphUrl(attrs),
      grafanaUrl: this.buildGrafanaUrl(attrs)
    };
  },

  buildLogsUrl(attrs) {
    const base = attrs.alert.logs_url;
    if (!base) return;
    const start = attrs.alert.starts_at;
    const end = attrs.alert.ends_at || new Date().toISOString();
    return `${base}#/discover?_g=(time:(from:'${start}',mode:absolute,to:'${end}'))`;
  },

  buildGraphUrl(attrs) {
    const base = attrs.alert.graph_url;
    if (!base) return;
    const url = new URL(base);

    const start = new Date(attrs.alert.starts_at);
    const end = attrs.alert.ends_at
      ? new Date(attrs.alert.ends_at)
      : new Date();

    // Make the graph window 5 minutes either side of the alert
    const windowDuration = (end - start) / 1000 + 600; // Add 10 minutes
    const windowEndDate = new Date(end.getTime() + 300 * 1000); // Shift 5 minutes forward

    url.searchParams.set("g0.range_input", `${Math.ceil(windowDuration)}s`);
    url.searchParams.set("g0.end_input", windowEndDate.toISOString());
    url.searchParams.set("g0.tab", "0");

    return url.toString();
  },

  buildGrafanaUrl(attrs) {
    const base = attrs.alert.grafana_url;
    if (!base) return;
    const url = new URL(base);

    const start = new Date(attrs.alert.starts_at);

    const end = attrs.alert.ends_at
      ? new Date(attrs.alert.ends_at)
      : new Date();

    // Grafana uses milliseconds since epoch
    url.searchParams.set("from", start.getTime());
    url.searchParams.set("to", end.getTime());

    return url.toString();
  },

  template: hbs`
    <td><a href={{transformed.graphUrl}}>{{attrs.alert.identifier}}</a></td>
    <td>
      {{alert-receiver-date-range 
          startsAt=attrs.alert.starts_at
          endsAt=attrs.alert.ends_at
        }}
    </td>
    {{#if attrs.showDescription}}
      <td>{{attrs.alert.description}}</td>
    {{/if}}
    <td>
      <div>
        <a href={{transformed.logsUrl}}>{{emoji name='file_folder'}}</a>
        {{#if transformed.grafanaUrl}}
          <a href={{transformed.grafanaUrl}}>{{emoji name='bar_chart'}}</a>
        {{/if}}
      </div>
    </td>
  `
});

createWidget("alert-receiver-collapsible-table", {
  tagName: "div.collapsible-table",

  template: hbs`
    <details>
      <summary>{{attrs.heading}} ({{attrs.alerts.length}})</summary>
      {{yield}}
    </details>
  `
});

createWidget("alert-receiver-table", {
  tagName: "div",

  buildClasses() {
    return `md-table`;
  },

  buildAttributes(attrs) {
    return {
      "data-alert-status": attrs.status
    };
  },

  transform(attrs) {
    return {
      showDescriptionColumn: attrs.alerts.any(a => a.description)
    };
  },

  template: hbs`
    <table class="prom-alerts-table">
      <thead>
        <tr>
          <th><a href={{attrs.headingLink}}>{{attrs.heading}}</a></th>
          <th></th>
          {{#if transformed.showDescriptionColumn}}<th></th>{{/if}}
          <th></th>
        </tr>
      </thead>
      <tbody>        
        {{#each attrs.alerts as |alert|}}
          {{alert-receiver-row alert=alert showDescription=this.transformed.showDescriptionColumn}}
        {{/each}}
      </tbody>
    </table>
  `
});
