import Component from "@glimmer/component";
import { inject as service } from "@ember/service";
import I18n from "I18n";
import { action } from "@ember/object";
export default class AlertReceiverRow extends Component {
  @service appEvents;
  @service siteSettings;

  get generatorUrl() {
    const {
      generator_url: url,
      starts_at: startsAt,
      ends_at: endsAt,
    } = this.args.alert;
    return this.processUrl(url, startsAt, endsAt);
  }

  get linkUrl() {
    const {
      link_url: url,
      starts_at: startsAt,
      ends_at: endsAt,
    } = this.args.alert;
    return this.processUrl(url, startsAt, endsAt);
  }

  get linkText() {
    return (
      this.args.alert.link_text || I18n.t("prom_alert_receiver.actions.link")
    );
  }

  processUrl(urlString, startsAt, endsAt) {
    endsAt ||= new Date().toISOString();
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
  }

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
  }

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
  }

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
  }

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
  }

  @action
  quoteAlert() {
    const {
      identifier,
      datacenter,
      description,
      starts_at: startsAt,
    } = this.args.alert;
    const [date, time] = startsAt.split("T");

    let alertString = `**${identifier}** - ${datacenter}`;
    alertString += ` - [date=${date} time=${time} displayedTimezone=UTC format="YYYY-MM-DD HH:mm"]`;
    if (description) {
      alertString += ` - ${description}`;
    }

    this.appEvents.trigger("alerts:quote-alert", alertString);
  }
}
