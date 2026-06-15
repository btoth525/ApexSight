# Changelog

## 1.0.0

- Initial release.
- Subscribes to Frigate's MQTT `frigate/reviews` and forwards new alerts to the
  ApexSight push relay (`/v1/notify`) with the household pairing code.
- Auto-discovers the Home Assistant MQTT broker (`services: mqtt:need`); manual
  `mqtt_*` overrides supported.
- Dedupes each review so it notifies once; builds the notification title/body
  from camera, objects, sub-labels and zones, plus the first detection's
  `preview.gif` / `snapshot.jpg` for the image.
