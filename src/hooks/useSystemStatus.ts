import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, type SystemStatus } from '@/lib/api';

export interface ConnectionLog {
  time: string;
  message: string;
  type: 'info' | 'error' | 'success';
}

export function useSystemStatus(intervalMs = 5000) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [logs, setLogs] = useState<ConnectionLog[]>([]);
  const intervalRef = useRef<number | null>(null);
  const wasConnected = useRef(false);

  const addLog = useCallback((message: string, type: ConnectionLog['type']) => {
    const time = new Date().toLocaleTimeString('sv-SE', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    setLogs(prev => [...prev.slice(-49), { time, message, type }]);
  }, []);

  const poll = useCallback(async () => {
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setError(null);
      if (!wasConnected.current) {
        addLog('Ansluten till Pi', 'success');
        wasConnected.current = true;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Anslutning misslyckades';
      setError(msg);
      if (wasConnected.current) {
        addLog('Tappade anslutning: ' + msg, 'error');
        wasConnected.current = false;
      } else if (loading) {
        addLog('Kunde inte ansluta: ' + msg, 'error');
      }
    } finally {
      setLoading(false);
    }
  }, [addLog, loading]);

  useEffect(() => {
    addLog('Ansluter till API...', 'info');
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

  return { status, error, loading, logs, refresh: poll };
}
