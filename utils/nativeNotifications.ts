import * as Notifications from "expo-notifications";

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

export async function ensureNotificationPermission(): Promise<boolean> {
  const existing = await Notifications.getPermissionsAsync();
  if (existing.granted) return true;
  const requested = await Notifications.requestPermissionsAsync({
    ios: { allowAlert: true, allowBadge: true, allowSound: true },
  });
  return requested.granted;
}

export async function notifyFrigateEvent(input: {
  title: string;
  body: string;
  eventId?: string;
  camera?: string;
}) {
  const granted = await ensureNotificationPermission();
  if (!granted) return;

  await Notifications.scheduleNotificationAsync({
    content: {
      title: input.title,
      body: input.body,
      sound: "default",
      data: {
        eventId: input.eventId,
        camera: input.camera,
      },
    },
    trigger: null,
  });
}
