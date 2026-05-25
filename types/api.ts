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
  days: number;
  total_events: number;
  today_count: number;
  yesterday_count: number;
  after_hours_count: number;
  cameras: Array<{
    camera: string;
    count: number;
  }>;
  labels: Array<{
    label: string;
    count: number;
  }>;
  sub_labels: Array<{ sub_label: string; count: number }>;
  zones: Array<{ zone: string; count: number }>;
  hours: Array<{ hour: number; count: number }>;
  daily: Array<{ date: string; count: number }>;
  recent_alerts: Array<{
    id: string;
    camera: string;
    start_time: number;
    end_time: number;
    event_id: string;
    objects: string[];
    zones: string[];
    threat_level: 0 | 1 | 2;
    title: string;
  }>;
};

export type GuardStatus = {
  active: boolean;
  started_at?: number;
  start_time?: number;
  camera_count?: number;
  cameras?: string[];
};

export type VLMMonitor = {
  id: string;
  camera: string;
  camera_friendly: string;
  condition: string;
  status: string;
  start_time?: number;
  end_time?: number;
  auto_renew: boolean;
  iteration_count: number;
  last_reasoning?: string;
};

export type VLMMonitorsResponse = {
  watches: VLMMonitor[];
};
