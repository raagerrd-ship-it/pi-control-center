import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, fetchPing, type SystemStatus } from '@/lib/api';
import { useActivityLog } from '@/hooks/useActivityLog';

const BASE_INTERVAL = 5000;
const MAX_INTERVAL = 60000;

export type ConnectionState = 'connected' | 'busy' | 'offline';

export function useSystemStatus() {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [connection, setConnection] = useState<ConnectionState>('offline');
  const intervalRef = useRef<number | null>(null);
  const wasConnected = useRef(false);
  const failCount = useRef(0);
  const loadingRef = useRef(true);
  const { addEntry } = useActivityLog();
  const addEntryRef = useRef(addEntry);
  addEntryRef.current = addEntry;

  const pollRef = useRef<() => Promise<void>>();

  const scheduleNext = useCallback(() => {
    if (intervalRef.current) clearTimeout(intervalRef.current);
    const delay = Math.min(BASE_INTERVAL * Math.pow(2, failCount.current), MAX_INTERVAL);
    intervalRef.current = window.setTimeout(() => pollRef.current?.(), delay);
  }, []);

  const poll = useCallback(async () => {
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setError(null);
      setConnection('connected');
      failCount.current = 0;
      if (!wasConnected.current) {
        wasConnected.current = true;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Anslutning misslyckades';
      setError(msg);
      failCount.current++;
      // Ping to distinguish busy vs offline
      let reachable = false;
      try { reachable = await fetchPing(); } catch {}
      setConnection(reachable ? 'busy' : 'offline');
      wasConnected.current = false;
    } finally {
      setLoading(false);
      loadingRef.current = false;
      scheduleNext();
    }
  }, [scheduleNext]);

  pollRef.current = poll;

  useEffect(() => {
    // Silent connect — no log spam
    poll();

    const handleVisibility = () => {
      if (document.hidden) {
        if (intervalRef.current) {
          clearTimeout(intervalRef.current);
          intervalRef.current = null;
        }
      } else {
        failCount.current = 0;
        poll();
      }
    };

    document.addEventListener('visibilitychange', handleVisibility);

    return () => {
      if (intervalRef.current) clearTimeout(intervalRef.current);
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, [poll]);

  return { status, error, loading, connection, refresh: poll };
}
