import Component from "@glimmer/component";

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
}
