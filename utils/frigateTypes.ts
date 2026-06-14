export type FrigateEvent = {
  id: string;
  camera: string;
  label: string;
  sub_label?: string | null;
  start_time?: number;
  end_time?: number;
  score?: number;
  top_score?: number;
  false_positive?: boolean;
  zones?: string[];
  has_clip?: boolean;
  has_snapshot?: boolean;
  retain_indefinitely?: boolean;
};

export type CameraConfig = Record<string, unknown>;
