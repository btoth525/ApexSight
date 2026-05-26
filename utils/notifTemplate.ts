import { formatLabel, getLabelEmoji } from "./labelUtil";

export type NotifVars = {
  label: string;
  camera: string;
  score?: number;
};

const DEFAULTS = {
  title: "{emoji} {label} · {camera}",
  body: "Tap to review",
};

export const NOTIF_DEFAULTS = DEFAULTS;

export const AVAILABLE_VARS = [
  { tag: "{emoji}",   desc: "Label emoji (🚶 🚗 🐕…)" },
  { tag: "{label}",   desc: "Object type (Person, Car…)" },
  { tag: "{camera}",  desc: "Camera name" },
  { tag: "{score}",   desc: "Confidence % (e.g. 87%)" },
];

export function renderNotifTemplate(template: string, vars: NotifVars): string {
  return template
    .replace(/\{emoji\}/g,   getLabelEmoji(vars.label))
    .replace(/\{label\}/g,   formatLabel(vars.label))
    .replace(/\{camera\}/g,  vars.camera.replace(/_/g, " "))
    .replace(/\{score\}/g,   vars.score != null ? `${Math.round(vars.score * 100)}%` : "");
}
