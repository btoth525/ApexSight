export type CameraConfig = {
  name: string;
  enabled: boolean;
  width: number;
  height: number;
  fps: number;
  detect: {
    enabled: boolean;
    width: number;
    height: number;
    fps: number;
  };
  objects: {
    track: string[];
  };
  zones: Record<string, ZoneConfig>;
  record: {
    enabled: boolean;
    retain: {
      days: number;
      mode: string;
    };
  };
  snapshots: {
    enabled: boolean;
    retain: {
      default: number;
    };
  };
};

export type ZoneConfig = {
  coordinates: string;
  objects: string[];
};

export type FrigateConfig = {
  cameras: Record<string, CameraConfig>;
  version?: string;
};

export type CameraState = {
  name: string;
  motion_threshold: number;
  motion_contour_area: number;
  read_start: number;
  ffmpeg_pid: number;
  frame_count: number;
  skipped_fps: number;
  detection_fps: number;
  pid: number;
  capture_pid: number;
};
