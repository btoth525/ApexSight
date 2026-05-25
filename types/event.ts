export type FrigateEvent = {
  id: string;
  camera: string;
  frame_time: number;
  snapshot: {
    frame_time: number;
    box: [number, number, number, number];
    area: number;
    region: [number, number, number, number];
    score: number;
    attributes: Record<string, number>;
  } | null;
  label: string;
  sub_label: string | null;
  top_score: number;
  false_positive: boolean | null;
  start_time: number;
  end_time: number | null;
  score: number;
  box: [number, number, number, number] | null;
  area: number | null;
  ratio: number | null;
  region: [number, number, number, number] | null;
  stationary: boolean;
  motionless_count: number;
  position_changes: number;
  current_zones: string[];
  entered_zones: string[];
  has_clip: boolean;
  has_snapshot: boolean;
  attributes: Record<string, number>;
  plus_id: string | null;
  model_hash: string | null;
  detector_type: string | null;
  model_type: string | null;
  data: {
    top_score: number;
    score: number;
    box: [number, number, number, number];
    area: number;
    region: [number, number, number, number];
    ratio: number;
    attr: Record<string, number>;
  };
};

export type ReviewItem = {
  id: string;
  camera: string;
  start_time: number;
  end_time: number | null;
  severity: "alert" | "detection" | "significant_motion";
  thumb_path: string;
  data: {
    detections: string[];
    objects: string[];
    sub_labels: string[];
    zones: string[];
    audio: string[];
  };
  has_been_reviewed: boolean;
};
