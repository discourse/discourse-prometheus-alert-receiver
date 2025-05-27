import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import CollapseToggle from "./collapse-toggle";
import Row from "./row";

export default class AlertReceiverTable extends Component {
  @tracked collapsed;

  get isCollapsed() {
    return this.collapsed ?? this.args.defaultCollapsed;
  }

  get showDescriptionColumn() {
    return this.args.alerts.any((a) => a.description);
  }

  @action
  toggleCollapsed() {
    this.collapsed = !this.isCollapsed;
  }

  <template>
    <div class="alert-receiver-table" data-alert-status={{@statusName}}>
      <CollapseToggle
        @heading={{@heading}}
        @count={{@alerts.length}}
        @headingLink={{@headingLink}}
        @collapsed={{this.isCollapsed}}
        @toggleCollapsed={{this.toggleCollapsed}}
      />

      {{#unless this.isCollapsed}}
        <div class="alert-table-wrapper">
          <table class="prom-alerts-table">
            <tbody>
              {{#each @alerts as |alert|}}
                <Row
                  @alert={{alert}}
                  @showDescription={{this.showDescriptionColumn}}
                />
              {{/each}}
            </tbody>
          </table>
        </div>
      {{/unless}}
    </div>
  </template>
}
