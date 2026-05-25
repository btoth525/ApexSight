import { useEffect } from "react";
import { useRouter } from "expo-router";
import * as Notifications from "expo-notifications";
import { useAuthStore } from "@/stores/authStore";

export function NotificationHandler() {
  const router = useRouter();
  const { token, baseUrl } = useAuthStore();

  useEffect(() => {
    const sub = Notifications.addNotificationResponseReceivedListener((response) => {
      const { actionIdentifier, notification } = response;
      const data = notification.request.content.data as Record<string, string>;

      switch (actionIdentifier) {
        case "MARK_REVIEWED":
          fetch(`${baseUrl}/api/reviews/viewed`, {
            method: "POST",
            headers: {
              Cookie: `frigate_token=${token}`,
              "X-CSRF-TOKEN": "1",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ ids: [data.id] }),
          }).catch(console.warn);
          break;

        case "SILENCE_30":
          fetch(`${baseUrl}/api/notifications/suspend/${data.camera}`, {
            method: "POST",
            headers: {
              Cookie: `frigate_token=${token}`,
              "X-CSRF-TOKEN": "1",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ minutes: 30 }),
          }).catch(console.warn);
          break;

        case "VIEW_CLIP":
          router.push(`/review?event_id=${data.id}`);
          break;

        case "VIEW_LIVE":
          router.push(`/?camera=${data.camera}`);
          break;

        case "OPEN_HUB":
          router.push("/ai-hub");
          break;

        default:
          if (data.link) router.push(data.link as `/${string}`);
      }
    });

    return () => sub.remove();
  }, [token, baseUrl]);

  return null;
}
