import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, fetchPing, type SystemStatus } from '@/lib/api';

const BASE_INTERVAL = 5000;
const BUSY_INTERVAL = 10000;
const MAX_INTERVAL = 60000;
const GRACE_THRESHOLD = 3;

export type ConnectionState = 'connected' | 'busy' | 'offline';

export function useSystemStatus(isBusy = false) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [connection, setConnection] = useState<ConnectionState>('offline');
  const intervalRef = useRef<number | null>(null);
  const failCount = useRef(0);
  const isBusyRef = useRef(isBusy);
  isBusyRef.current = isBusy;

  const pollRef = useRef<() => Promise<void>>();

  const scheduleNext = useCallback(() => {
    if (intervalRef.current) clearTimeout(intervalRef.current);
    const base = isBusyRef.current ? BUSY_INTERVAL : BASE_INTERVAL;
    const delay = Math.min(base * Math.pow(2, failCount.current), MAX_INTERVAL);
    intervalRef.current = window.setTimeout(() => pollRef.current?.(), delay);
  }, []);

  const poll = useCallback(async () => {
    try {
      const timeoutMs = isBusyRef.current ? 8000 : 4000;
      const data = await fetchSystemStatus(timeoutMs);
      setStatus(data);
      setError(null);
      setConnection('connected');
      failCount.current = 0;
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Anslutning misslyckades';
      setError(msg);
      failCount.current++;

      // Grace period: keep current connection state until GRACE_THRESHOLD consecutive fails
      if (failCount.current < GRACE_THRESHOLD) {
        // Don't change connection state — could be a transient timeout
      } else if (isBusyRef.current) {
        // Known operation active — mark busy, skip ping to reduce load
        setConnection('busy');
      } else {
        // No known operation — ping to distinguish busy vs offline
        let reachable = false;
        try { reachable = await fetchPing(); } catch {}
        setConnection(reachable ? 'busy' : 'offline');
      }
    } finally {
      setLoading(false);
      scheduleNext();
    }
  }, [scheduleNext]);

  pollRef.current = poll;

  useEffect(() => {
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
