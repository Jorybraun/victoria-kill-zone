import {LoadReporter} from "./load-reporter.js";

/** Explicit diagnostic run; never a load acceptance result. */
export default class CatchUpReporter extends LoadReporter {
  constructor() {super("last-catch-up.json", "local-workerd-authenticated-handler-diagnostic");}
}
