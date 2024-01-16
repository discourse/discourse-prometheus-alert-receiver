import Component from "@glimmer/component";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";
import { applyLocalDates } from "discourse/lib/local-dates";

export default class AlertReceiverDate extends Component {
  @service siteSettings;

  @action
  applyLocalDates(element) {
    applyLocalDates([element], this.siteSettings);
  }
}
