import { Action, ActionPanel, Form, Icon, showToast, Toast } from "@raycast/api";
import { stat } from "node:fs/promises";
import { sendCommand } from "./buddycam";

type Values = { mode: string; format: string; source: string; cameraUrl: string; folder: string[] };

export default function Command() {
  async function record(values: Values) {
    if (!["camera", "screen"].includes(values.mode) || !["1:1", "9:16", "16:9"].includes(values.format)) {
      await showToast({ style: Toast.Style.Failure, title: "Choose a recording mode and format" });
      return;
    }
    const url = new URL("buddycam://record");
    url.searchParams.set("mode", values.mode);
    url.searchParams.set("format", values.format);
    if (["usb", "network"].includes(values.source)) {
      url.searchParams.set("source", values.source);
    }
    if (values.source === "network" && values.cameraUrl.trim()) {
      url.searchParams.set("camera_url", values.cameraUrl.trim());
    }
    const folder = values.folder[0];
    if (folder) {
      try {
        if (!(await stat(folder)).isDirectory()) throw new Error("Not a directory");
        url.searchParams.set("folder", folder);
      } catch {
        await showToast({ style: Toast.Style.Failure, title: "Choose an existing folder" });
        return;
      }
    }
    await sendCommand(url);
  }

  return (
    <Form actions={<ActionPanel><Action.SubmitForm title="Start Recording" icon={Icon.Video} onSubmit={record} /></ActionPanel>}>
      <Form.Dropdown id="mode" title="Record" defaultValue="camera" storeValue>
        <Form.Dropdown.Item value="camera" title="Camera only" />
        <Form.Dropdown.Item value="screen" title="Screen + camera" />
      </Form.Dropdown>
      <Form.Dropdown id="source" title="Source" defaultValue="usb" storeValue>
        <Form.Dropdown.Item value="usb" title="USB" />
        <Form.Dropdown.Item value="network" title="Network (WiFi / Tailscale)" />
      </Form.Dropdown>
      <Form.Dropdown id="format" title="Format" defaultValue="9:16" storeValue>
        <Form.Dropdown.Item value="1:1" title="1:1" />
        <Form.Dropdown.Item value="9:16" title="9:16" />
        <Form.Dropdown.Item value="16:9" title="16:9" />
      </Form.Dropdown>
      <Form.TextField
        id="cameraUrl"
        title="Stream URL"
        placeholder="http://192.168.1.10:8080/video (empty = saved address)"
        storeValue
      />
      <Form.FilePicker id="folder" title="Save to" canChooseDirectories canChooseFiles={false} allowMultipleSelection={false} storeValue />
    </Form>
  );
}
