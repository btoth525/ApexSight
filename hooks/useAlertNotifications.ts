import { useCallback, useEffect, useRef } from "react";
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

// Download the snapshot to a local file so iOS can attach it to the notification.
async function downloadSnapshot(snapshotUrl: string, token: string | null): Promise<string | null> {
  try {
    const ext = ".jpg";
    const filename = `apex_snap_${Date.now()}${ext}`;
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
  const { notificationsEnabled } = useSettingsStore();
  const recentIds = useRef<Set<string>>(new Set());

  const onEvent = useCallback(async (event: unknown) => {
    if (!notificationsEnabled) return;
    const e = event as FrigateWsEvent;

    // Trigger on new alert-severity events
    const after = e.after;
    if (!after?.id || !after.camera || !after.label) return;
    if (e.type !== "new" && e.type !== "update") return;
    // Only alert severity → push notification
    const isAlert = after.severity === "alert" || after.data?.severity === "alert";
    if (!isAlert) return;
    // Dedupe by event id
    if (recentIds.current.has(after.id)) return;
    recentIds.current.add(after.id);
    if (recentIds.current.size > 100) {
      recentIds.current = new Set(Array.from(recentIds.current).slice(-50));
    }

    const snapshotUrl = `${baseUrl}/api/events/${after.id}/snapshot.jpg`;
    const localPath = await downloadSnapshot(snapshotUrl, token);

    const cameraLabel = after.camera.replace(/_/g, " ");
    await Notifications.scheduleNotificationAsync({
      content: {
        title: `${getLabelEmoji(after.label)} ${formatLabel(after.label)} detected`,
        body: `On ${cameraLabel}`,
        data: { event_id: after.id, camera: after.camera, type: "alert" },
        categoryIdentifier: "FRIGATE_ALERT",
        sound: "default",
        ...(localPath
          ? { attachments: [{ identifier: "snapshot", url: localPath, type: "image/jpeg" }] }
          : {}),
      },
      trigger: null,
    });
  }, [baseUrl, token, notificationsEnabled]);

  useFrigateEvents(onEvent);
}
