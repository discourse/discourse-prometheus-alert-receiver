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
  "alert-receiver-row",
  "tr",
  hbs`<AlertReceiver::Row
        @alert={{@data.alert}}
        @showDescription={{@data.showDescription}}
      />`
);

registerWidgetShim(
  "alert-receiver-external-link",
  "div.external-link",
  hbs`<AlertReceiver::ExternalLink @link={{@data.link}} />`
);

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

  template: widgetHbs`
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

  template: widgetHbs`
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
