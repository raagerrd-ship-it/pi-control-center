import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, type SystemStatus } from '@/lib/api';
import { useActivityLog } from '@/hooks/useActivityLog';

export function useSystemStatus(intervalMs = 5000) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const intervalRef = useRef<number | null>(null);
  const wasConnected = useRef(false);
  const { addEntry } = useActivityLog();

  const poll = useCallback(async () => {
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setError(null);
      if (!wasConnected.current) {
        addEntry('SYSTEM', 'Ansluten till Pi', 'success');
        wasConnected.current = true;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Anslutning misslyckades';
      setError(msg);
      if (wasConnected.current) {
        addEntry('SYSTEM', 'Tappade anslutning: ' + msg, 'error');
        wasConnected.current = false;
      } else if (loading) {
        addEntry('SYSTEM', 'Kunde inte ansluta: ' + msg, 'error');
      }
    } finally {
      setLoading(false);
    }
  }, [addEntry, loading]);

  useEffect(() => {
    addEntry('SYSTEM', 'Ansluter till API...', 'info');
    poll();
    intervalRef.current = window.setInterval(poll, intervalMs);

    const handleVisibility = () => {
      if (document.hidden) {
        if (intervalRef.current) {
          clearInterval(intervalRef.current);
          intervalRef.current = null;
        }
      } else {
        poll();
        intervalRef.current = window.setInterval(poll, intervalMs);
      }
    };

    document.addEventListener('visibilitychange', handleVisibility);

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, [poll, intervalMs]);

  return { status, error, loading, refresh: poll };
}
