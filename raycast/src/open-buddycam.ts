import { sendCommand } from "./buddycam";

export default async function Command() {
  await sendCommand(new URL("buddycam://open"));
}
