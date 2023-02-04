import I18n from "I18n";
import { createWidget } from "discourse/widgets/widget";
import widgetHbs from "discourse/widgets/hbs-compiler";
import { hbs } from "ember-cli-htmlbars";
import { h } from "virtual-dom";
import { registerWidgetShim } from "discourse/widgets/render-glimmer";

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

registerWidgetShim(
  "alert-receiver-table",
  "div.alert-receiver-table",
  hbs`<AlertReceiver::Table
        @alerts={{@data.alerts}}
        @heading={{@data.heading}}
        @headingLink={{@data.headingLink}}
        @defaultCollapsed={{@data.defaultCollapsed}}
      />`
);
