import Component from "@glimmer/component";
import { cached } from "@glimmer/tracking";

const STATUS_NAMES = ["firing", "suppressed", "stale", "resolved"];
const STATUS_EMOJIS = {
  firing: "fire",
  suppressed: "shushing_face",
};

const COLLAPSE_THRESHOLD = 30;

export default class AlertReceiverData extends Component {
  @cached
  get groupedByStatus() {
    const alerts = this.args.topic.get("alert_data");

    const byStatus = {};
    const statusCounts = {};

    alerts.forEach((a) => {
      const byDc = (byStatus[a.status] ??= {});
      statusCounts[a.status] ??= 0;
      const listForStatusAndDc = (byDc[a.datacenter] ??= []);
      listForStatusAndDc.push(a);
      statusCounts[a.status] += 1;
    });

    let defaultCollapsed = false;

    return STATUS_NAMES.map((statusName) => {
      const byDc = byStatus[statusName];
      if (!byDc) {
        return;
      }

      if (statusCounts[statusName] > COLLAPSE_THRESHOLD) {
        defaultCollapsed = true;
      }

      const orderedDcData = Object.entries(byDc)
        .map(([dcName, dcAlerts]) => {
          return {
            alerts: dcAlerts,
            dcName,
            headingLink: dcAlerts[0].external_url,
          };
        })
        .sort((a, b) => (a.dcName > b.dcName ? 1 : -1));

      return {
        emoji: STATUS_EMOJIS[statusName],
        titleKey: `prom_alert_receiver.headers.${statusName}`,
        defaultCollapsed,
        groupedByDc: orderedDcData,
      };
    }).filter(Boolean);
  }
}
