import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, type SystemStatus } from '@/lib/api';

export function useSystemStatus(intervalMs = 5000) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const intervalRef = useRef<number | null>(null);

  const poll = useCallback(async () => {
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection failed');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Start polling
    poll();
    intervalRef.current = window.setInterval(poll, intervalMs);

    // Pause polling when tab is hidden (saves CPU + network on Pi)
    const handleVisibility = () => {
      if (document.hidden) {
        if (intervalRef.current) {
          clearInterval(intervalRef.current);
          intervalRef.current = null;
        }
      } else {
        poll(); // Immediate refresh on return
        intervalRef.current = window.setInterval(poll, intervalMs);
      }
    };

    document.addEventListener('visibilitychange', handleVisibility);

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, [poll, intervalMs]);

  return { status, error, loading };
}
