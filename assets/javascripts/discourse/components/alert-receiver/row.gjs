import Component from "@glimmer/component";
import { inject as controller } from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";
import DateRange from "./date-range";

export default class AlertReceiverRow extends Component {
  @service siteSettings;
  @controller("topic") topicController;

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
      this.args.alert.link_text || i18n("prom_alert_receiver.actions.link")
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

    this.topicController.quoteState.selected(
      this.topicController.model.postStream.stream[0],
      alertString,
      {}
    );
    this.topicController.send("selectText");
  }

  <template>
    <tr>
      <td><a href={{this.generatorUrl}}>{{@alert.identifier}}</a></td>
      <td>
        <DateRange @startsAt={{@alert.starts_at}} @endsAt={{@alert.ends_at}} />
      </td>
      {{#if @showDescription}}
        <td>{{@alert.description}}</td>
      {{/if}}
      <td>
        <div>
          {{#if this.linkUrl}}
            <a
              class="btn btn-flat no-text btn-icon"
              href={{this.linkUrl}}
              title={{this.linkText}}
            >
              {{icon "up-right-from-square"}}
            </a>
          {{/if}}
          <DButton
            @action={{this.quoteAlert}}
            @icon="quote-left"
            @title="prom_alert_receiver.actions.quote"
            class="btn-flat"
          />
        </div>
      </td>
    </tr>
  </template>
}
