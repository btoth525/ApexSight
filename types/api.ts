export type ApiResponse<T> = {
  data: T;
  status: number;
};

export type LoginRequest = {
  user: string;
  password: string;
};

export type LoginResponse = {
  token: string;
  user: {
    name: string;
  };
};

export type AIInsights = {
  cameras: Array<{
    name: string;
    total_events: number;
    top_labels: string[];
    thumbnail?: string;
  }>;
  labels: Array<{
    label: string;
    count: number;
    percentage: number;
  }>;
  heatmap?: number[][];
  recent_events: Array<{
    id: string;
    camera: string;
    label: string;
    start_time: number;
    thumbnail_path?: string;
  }>;
  stats: {
    total_events_today: number;
    total_events_week: number;
    active_cameras: number;
    detection_rate: number;
  };
};

export type GuardStatus = {
  active: boolean;
  start_time?: number;
  cameras: string[];
};

export type VLMMonitor = {
  id: string;
  camera: string;
  prompt: string;
  active: boolean;
  created_at: number;
  last_triggered?: number;
};
