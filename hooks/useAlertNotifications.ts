import { useCallback, useEffect, useRef } from "react";
import * as Notifications from "expo-notifications";
import * as FileSystem from "expo-file-system";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { useFrigateEvents } from "./useFrigateEvents";
import { renderNotifTemplate } from "@/utils/notifTemplate";

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
    // Race the download against a 2-second timeout so notifications never
    // wait on a slow/missing snapshot. If the image isn't ready in 2s the
    // notification fires without it — speed > pretty.
    const result = await Promise.race([
      FileSystem.downloadAsync(snapshotUrl, dest, { headers }),
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 2000)),
    ]);
    if (!result) return null;
    return result.status === 200 ? result.uri : null;
  } catch {
    return null;
  }
}

// Register iOS notification action categories once on mount.
// "View Clip" opens the app, "Mark Reviewed" runs silently in the background.
async function registerCategories(actionsEnabled: boolean) {
  if (actionsEnabled) {
    await Notifications.setNotificationCategoryAsync("FRIGATE_ALERT", [
      {
        identifier: "VIEW_CLIP",
        buttonTitle: "View Clip",
        options: { opensAppToForeground: true },
      },
      {
        identifier: "MARK_REVIEWED",
        buttonTitle: "Mark Reviewed",
        options: { opensAppToForeground: false },
      },
    ]);
  } else {
    await Notifications.deleteNotificationCategoryAsync("FRIGATE_ALERT").catch(() => {});
  }
}

export function useAlertNotifications() {
  const { baseUrl, token } = useAuthStore();
  const {
    notificationsEnabled, allowedCameras, allowedLabels,
    notifTitle, notifBody, notifActionsEnabled,
  } = useSettingsStore();
  const notifiedIds = useRef<Set<string>>(new Set());

  // Re-register categories whenever the actions toggle changes
  useEffect(() => {
    registerCategories(notifActionsEnabled).catch(() => {});
  }, [notifActionsEnabled]);

  const onEvent = useCallback(async (event: unknown) => {
    if (!notificationsEnabled) return;
    const e = event as FrigateWsEvent;
    const after = e.after;

    if (!after?.id || !after.camera || !after.label) return;

    // One notification per event — only on first detection
    if (e.type !== "new") return;

    // Alert severity only
    const isAlert = after.severity === "alert" || after.data?.severity === "alert";
    if (!isAlert) return;

    // Camera and label filters
    if (allowedCameras.length > 0 && !allowedCameras.includes(after.camera)) return;
    if (allowedLabels.length > 0 && !allowedLabels.includes(after.label)) return;

    // Global dedup — prevents double-fire from server push + WebSocket
    if (notifiedIds.current.has(after.id)) return;
    notifiedIds.current.add(after.id);
    if (notifiedIds.current.size > 200) {
      notifiedIds.current = new Set(Array.from(notifiedIds.current).slice(-100));
    }

    const vars = { label: after.label, camera: after.camera };
    const title = renderNotifTemplate(notifTitle, vars);
    const body  = renderNotifTemplate(notifBody,  vars);

    const snapshotUrl = `${baseUrl}/api/events/${after.id}/snapshot.jpg`;
    const localPath = await downloadSnapshot(snapshotUrl, token);

    await Notifications.scheduleNotificationAsync({
      identifier: `alert-${after.id}`,
      content: {
        title,
        body,
        data: { event_id: after.id, camera: after.camera, type: "alert" },
        categoryIdentifier: notifActionsEnabled ? "FRIGATE_ALERT" : undefined,
        sound: "default",
        ...(localPath
          ? { attachments: [{ identifier: "snapshot", url: localPath, type: "image/jpeg" }] }
          : {}),
      },
      trigger: null,
    });
  }, [baseUrl, token, notificationsEnabled, allowedCameras, allowedLabels,
      notifTitle, notifBody, notifActionsEnabled]);

  useFrigateEvents(onEvent);
}
