import useSWR from "swr";
import { apiClient } from "@/utils/apiClient";

const fetcher = (url: string) => apiClient.get(url).then((r) => r.data);

export function useFrigateApi<T>(path: string | null) {
  return useSWR<T>(path, fetcher, { revalidateOnFocus: false });
}
