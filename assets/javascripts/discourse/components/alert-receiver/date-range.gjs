import Component from "@glimmer/component";
import Timestamp from "./timestamp";

function parseTimestamp(timestamp) {
  if (timestamp) {
    const [date, time] = timestamp.split("T");
    return { date, time };
  }
}

export default class AlertReceiverDateRange extends Component {
  get parsedStart() {
    return parseTimestamp(this.args.startsAt);
  }

  get parsedEnd() {
    return parseTimestamp(this.args.endsAt);
  }

  get hideEndDate() {
    return this.parsedStart.date === this.parsedEnd?.date;
  }

  <template>
    <span>
      <Timestamp
        @date={{this.parsedStart.date}}
        @time={{this.parsedStart.time}}
      />

      {{#if @endsAt}}
        -&nbsp;<Timestamp
          @date={{this.parsedEnd.date}}
          @time={{this.parsedEnd.time}}
          @hideDate={{this.hideEndDate}}
        />
      {{/if}}
    </span>
  </template>
}
