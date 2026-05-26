import { useCallback, useRef } from "react";
import * as Notifications from "expo-notifications";
import * as FileSystem from "expo-file-system";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { useFrigateEvents } from "./useFrigateEvents";
import { formatLabel, getLabelEmoji } from "@/utils/labelUtil";

type FrigateWsEvent = {
  type?: string;
  before?: { id?: string; camera?: string; label?: string; severity?: string };
  after?:  { id?: string; camera?: string; label?: string; severity?: string;
             has_snapshot?: boolean; thumbnail?: string; data?: any };
};

async function downloadSnapshot(snapshotUrl: string, token: string | null): Promise<string | null> {
  try {
    const filename = `apex_snap_${Date.now()}.jpg`;
    const dest = `${FileSystem.cacheDirectory}${filename}`;
    const headers: Record<string, string> = {};
    if (token && token !== "session") headers["Cookie"] = `frigate_token=${token}`;
    const result = await FileSystem.downloadAsync(snapshotUrl, dest, { headers });
    return result.status === 200 ? result.uri : null;
  } catch {
    return null;
  }
}

export function useAlertNotifications() {
  const { baseUrl, token } = useAuthStore();
  const { notificationsEnabled, allowedCameras, allowedLabels } = useSettingsStore();
  const notifiedIds = useRef<Set<string>>(new Set());

  const onEvent = useCallback(async (event: unknown) => {
    if (!notificationsEnabled) return;
    const e = event as FrigateWsEvent;
    const after = e.after;

    if (!after?.id || !after.camera || !after.label) return;

    // Only fire on the very first detection ("new") — not on every update.
    // This guarantees exactly one notification per event regardless of how
    // many WebSocket update frames arrive or how many times this hook remounts.
    if (e.type !== "new") return;

    // Alert severity only
    const isAlert = after.severity === "alert" || after.data?.severity === "alert";
    if (!isAlert) return;

    // Camera and label filters (empty = all)
    if (allowedCameras.length > 0 && !allowedCameras.includes(after.camera)) return;
    if (allowedLabels.length > 0 && !allowedLabels.includes(after.label)) return;

    // Global dedup — survives remounts via ref, prevents double-fire
    // if server APNs push and WebSocket both arrive for the same event
    if (notifiedIds.current.has(after.id)) return;
    notifiedIds.current.add(after.id);
    if (notifiedIds.current.size > 200) {
      notifiedIds.current = new Set(Array.from(notifiedIds.current).slice(-100));
    }

    const snapshotUrl = `${baseUrl}/api/events/${after.id}/snapshot.jpg`;
    const localPath = await downloadSnapshot(snapshotUrl, token);

    const cameraName = after.camera.replace(/_/g, " ");
    const emoji = getLabelEmoji(after.label);
    const label = formatLabel(after.label);

    await Notifications.scheduleNotificationAsync({
      // Use the event ID as the iOS notification identifier.
      // If a server APNs push arrives for the same event later, iOS will
      // replace this notification rather than stacking a duplicate.
      identifier: `alert-${after.id}`,
      content: {
        title: `${emoji} ${label} · ${cameraName}`,
        body: "Tap to review",
        data: { event_id: after.id, camera: after.camera, type: "alert" },
        sound: "default",
        ...(localPath
          ? { attachments: [{ identifier: "snapshot", url: localPath, type: "image/jpeg" }] }
          : {}),
      },
      trigger: null,
    });
  }, [baseUrl, token, notificationsEnabled, allowedCameras, allowedLabels]);

  useFrigateEvents(onEvent);
}
