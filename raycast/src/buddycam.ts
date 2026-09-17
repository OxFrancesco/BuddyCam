import { closeMainWindow, open, showToast, Toast } from "@raycast/api";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export async function sendCommand(url: URL) {
  const app = join(homedir(), "Applications", "BuddyCam.app");
  try {
    await access(app);
    await open(url.toString(), app);
    await closeMainWindow();
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Couldn't open BuddyCam",
      message: error instanceof Error ? error.message : "Check that BuddyCam is installed in ~/Applications.",
    });
  }
}
