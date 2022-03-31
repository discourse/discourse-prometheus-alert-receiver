import I18n from "I18n";
import { createWidget } from "discourse/widgets/widget";
import hbs from "discourse/widgets/hbs-compiler";
import RawHtml from "discourse/widgets/raw-html";
import { h } from "virtual-dom";
import { applyLocalDates } from "discourse/lib/local-dates";

const STATUS_NAMES = ["firing", "suppressed", "stale", "resolved"];
const STATUS_EMOJIS = {
  firing: "fire",
  suppressed: "shushing_face",
};

const COLLAPSE_THRESHOLD = 30;

createWidget("alert-receiver-data", {
  tagName: "div",
  buildClasses() {
    return "prometheus-alert-receiver";
  },

  html(attrs) {
    const groupedByStatus = {};
    const statusCounts = {};

    attrs.alerts.forEach((a) => {
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

    let collapsed = false;

    STATUS_NAMES.forEach((statusName) => {
      const groupedByDc = groupedByStatus[statusName];
      if (!groupedByDc) {
        return;
      }

      const headerContent = [];
      if (STATUS_EMOJIS[statusName]) {
        headerContent.push(
          this.attach("emoji", { name: STATUS_EMOJIS[statusName] })
        );
        headerContent.push(" ");
      }
      headerContent.push(I18n.t(`prom_alert_receiver.headers.${statusName}`));
      content.push(h("h2", {}, headerContent));

      if (statusCounts[statusName] > COLLAPSE_THRESHOLD) {
        collapsed = true;
      }

      Object.entries(groupedByDc).forEach(([dcName, alerts]) => {
        const table = this.attach("alert-receiver-table", {
          status: statusName,
          alerts,
          heading: dcName,
          headingLink: alerts[0].external_url,
          defaultCollapsed: collapsed,
        });

        content.push(table);
      });
    });

    return content;
  },
});

createWidget("alert-receiver-date", {
  tagName: "span.alert-receiver-date",
  html(attrs) {
    if (!attrs.timestamp) {
      return;
    }

    const splitTimestamp = attrs.timestamp.split("T");
    if (!splitTimestamp.length === 2) {
      return;
    }

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
    applyLocalDates([dateElement], this.siteSettings);

    return new RawHtml({ html: dateElement.outerHTML });
  },
});

createWidget("alert-receiver-date-range", {
  tagName: "span",
  html(attrs) {
    const content = [];
    if (!attrs.startsAt) {
      return;
    }

    content.push(
      this.attach("alert-receiver-date", { timestamp: attrs.startsAt })
    );

    if (attrs.endsAt) {
      content.push(" - ");
      const startDate = attrs.startsAt.split("T")[0];
      const endDate = attrs.endsAt.split("T")[0];

      const hideDate = startDate === endDate;

      content.push(
        this.attach("alert-receiver-date", {
          timestamp: attrs.endsAt,
          hideDate,
        })
      );
    }

    return content;
  },
});

createWidget("alert-receiver-row", {
  tagName: "tr",

  transform(attrs) {
    const startsAt = attrs.alert.starts_at;
    const endsAt = attrs.alert.ends_at || new Date().toISOString();
    const linkText =
      this.attrs.alert.link_text || I18n.t("prom_alert_receiver.actions.link");

    return {
      generatorUrl: this.processUrl(
        attrs.alert.generator_url,
        startsAt,
        endsAt
      ),
      linkUrl: this.processUrl(attrs.alert.link_url, startsAt, endsAt),
      linkText,
    };
  },

  processUrl(urlString, startsAt, endsAt) {
    try {
      const url = new URL(urlString);

      return (
        this.buildPrometheusUrl(url, startsAt, endsAt) ||
        this.buildGrafanaUrl(url, startsAt, endsAt) ||
        this.buildKibanaUrl(url, startsAt, endsAt) ||
        url
      );
    } catch (e) {
      if (e instanceof TypeError) {
        // Invalid or blank URL
        return;
      }
      throw e;
    }
  },

  checkMatch(url, regexString) {
    if (!regexString || !url) {
      return false;
    }

    try {
      const regexp = new RegExp(regexString);
      return regexp.test(url);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("Alert receiver regex error", e);
    }

    return false;
  },

  buildKibanaUrl(url, startsAt, endsAt) {
    const regex = this.siteSettings.prometheus_alert_receiver_kibana_regex;
    if (!this.checkMatch(url, regex)) {
      return;
    }

    // Kibana stores its data after the # in the URL
    // So some custom parsing is required
    const fragment = url.hash;
    const parts = fragment.split("?", 2);

    const searchParams = new URLSearchParams(parts[1]);
    searchParams.set(
      "_g",
      `(time:(from:'${startsAt}',mode:absolute,to:'${endsAt}'))`
    );

    url.hash = `${parts[0]}?${searchParams}`;

    return url.toString();
  },

  buildPrometheusUrl(url, startsAt, endsAt) {
    const regex = this.siteSettings.prometheus_alert_receiver_prometheus_regex;
    if (!this.checkMatch(url, regex)) {
      return;
    }

    const start = new Date(startsAt);
    const end = new Date(endsAt);

    // Make the graph window 5 minutes either side of the alert
    const windowDuration = (end - start) / 1000 + 600; // Add 10 minutes
    const windowEndDate = new Date(end.getTime() + 300 * 1000); // Shift 5 minutes forward

    url.searchParams.set("g0.range_input", `${Math.ceil(windowDuration)}s`);
    url.searchParams.set("g0.end_input", windowEndDate.toISOString());
    url.searchParams.set("g0.tab", "0");

    return url.toString();
  },

  buildGrafanaUrl(url, startsAt, endsAt) {
    const regex = this.siteSettings.prometheus_alert_receiver_grafana_regex;
    if (!this.checkMatch(url, regex)) {
      return;
    }

    const start = new Date(startsAt);
    const end = new Date(endsAt);

    // Grafana uses milliseconds since epoch
    url.searchParams.set("from", start.getTime());
    url.searchParams.set("to", end.getTime());

    return url.toString();
  },

  quoteAlert(val) {
    let alertString = `**${val.identifier}** - ${val.datacenter}`;

    alertString += ` - [date=${val.starts_at.split("T")[0]} time=${
      val.starts_at.split("T")[1]
    } displayedTimezone=UTC format="YYYY-MM-DD HH:mm"]`;

    if (val.description) {
      alertString += ` - ${val.description}`;
    }

    this.appEvents.trigger("alerts:quote-alert", alertString);
  },

  template: hbs`
    <td><a href={{transformed.generatorUrl}}>{{attrs.alert.identifier}}</a></td>
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
        {{#if transformed.linkUrl}}
          <a class='btn-flat no-text btn-icon'
            href={{transformed.linkUrl}}
            title={{transformed.linkText}}>
            {{d-icon 'external-link-alt'}}
          </a>
        {{/if}}
        {{flat-button
          action="quoteAlert"
          icon="quote-left"
          actionParam=attrs.alert
          title="prom_alert_receiver.actions.quote"
        }}
      </div>
    </td>
  `,
});

createWidget("alert-receiver-external-link", {
  tagName: "div.external-link",
  click() {},
  template: hbs`
    <a target='_blank' href={{attrs.link}} title={{i18n "prom_alert_receiver.actions.alertmanager"}}>
      {{d-icon 'far-list-alt'}}
    </a>
  `,
});

createWidget("alert-receiver-collapse-toggle", {
  tagName: "div",

  buildClasses(attrs) {
    let classString = "alert-receiver-collapse-toggle";
    if (attrs.collapsed) {
      classString += " collapsed";
    }
    return classString;
  },

  click() {
    this.sendWidgetAction("toggleCollapse");
  },

  transform(attrs) {
    return {
      icon: attrs.collapsed ? "caret-right" : "caret-down",
    };
  },

  template: hbs`
    <div class='collapse-icon'>
      <a>{{d-icon this.transformed.icon}}</a>
    </div>
    <div class='heading'>
      {{attrs.heading}}
      ({{attrs.count}})
    </div>
    {{alert-receiver-external-link link=attrs.headingLink}}
  `,
});

createWidget("alert-receiver-table", {
  tagName: "div.alert-receiver-table",
  buildKey: (attrs) => `alert-table-${attrs.status}-${attrs.heading}`,

  buildAttributes(attrs) {
    return {
      "data-alert-status": attrs.status,
    };
  },

  transform(attrs, state) {
    return {
      showDescriptionColumn: attrs.alerts.any((a) => a.description),
      collapseToggleIcon: state.collapsed ? "caret-right" : "caret-down",
    };
  },

  defaultState(attrs) {
    return { collapsed: attrs.defaultCollapsed };
  },

  template: hbs`
    {{alert-receiver-collapse-toggle heading=attrs.heading count=attrs.alerts.length headingLink=attrs.headingLink collapsed=state.collapsed}}

    {{#unless state.collapsed}}
      <div class='alert-table-wrapper'>
        <table class="prom-alerts-table">
          <tbody>
            {{#each attrs.alerts as |alert|}}
              {{alert-receiver-row alert=alert showDescription=this.transformed.showDescriptionColumn}}
            {{/each}}
          </tbody>
        </table>
      </div>
    {{/unless}}
  `,

  toggleCollapse() {
    this.state.collapsed = !this.state.collapsed;
  },
});
