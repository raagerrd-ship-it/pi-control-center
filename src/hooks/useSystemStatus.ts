import { useState, useEffect, useCallback, useRef } from 'react';
import { fetchSystemStatus, type SystemStatus } from '@/lib/api';

const DEMO_STATUS: SystemStatus = {
  cpu: 23,
  temp: 47.2,
  ramUsed: 312,
  ramTotal: 512,
  diskUsed: 4,
  diskTotal: 16,
  uptime: '3d 7h 42m',
  dashboardCpu: 0.3,
  dashboardRamMb: 7,
  services: {
    'lotus-lantern': { online: true, installed: true, version: '3 apr', cpu: 4.2, ramMb: 38, cpuCore: 1 },
    'cast-away': { online: true, installed: true, version: '1 apr', cpu: 1.8, ramMb: 27, cpuCore: 2 },
    'sonos-gateway': { online: false, installed: true, version: '28 mar', cpu: 0, ramMb: 0, cpuCore: 3 },
  },
};

export function useSystemStatus(intervalMs = 5000) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [demo, setDemo] = useState(false);
  const intervalRef = useRef<number | null>(null);
  const failCount = useRef(0);

  const poll = useCallback(async () => {
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setError(null);
      failCount.current = 0;
      setDemo(false);
    } catch (e) {
      failCount.current++;
      // After 3 consecutive failures, switch to demo mode
      if (failCount.current >= 3) {
        setStatus(DEMO_STATUS);
        setError(null);
        setDemo(true);
      } else {
        setError(e instanceof Error ? e.message : 'Connection failed');
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
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

  return { status, error, loading, demo, refresh: poll };
}