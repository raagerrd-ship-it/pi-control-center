import { useState, useCallback, useEffect, useRef } from 'react';
import { triggerUpdate, fetchUpdateStatus, triggerInstall, fetchInstallStatus, serviceAction, type UpdateResult, type InstallResult, type ServiceActionResult } from '@/lib/api';

export function useServiceUpdate() {
  const [updates, setUpdates] = useState<Record<string, UpdateResult>>({});
  const [installs, setInstalls] = useState<Record<string, InstallResult>>({});
  const [actions, setActions] = useState<Record<string, ServiceActionResult | { status: 'pending'; action: string }>>({});
  const pollTimers = useRef<Record<string, number>>({});

  const pollUpdateStatus = useCallback((app: string) => {
    const timerKey = `update:${app}`;
    const poll = async () => {
      try {
        const result = await fetchUpdateStatus(app);
        setUpdates(prev => ({ ...prev, [app]: result }));
        if (result.status === 'updating') {
          pollTimers.current[timerKey] = window.setTimeout(poll, 3000);
        } else {
          delete pollTimers.current[timerKey];
        }
      } catch {
        pollTimers.current[timerKey] = window.setTimeout(poll, 5000);
      }
    };
    poll();
  }, []);

  const startUpdate = useCallback(async (app: string) => {
    const timerKey = `update:${app}`;
    if (pollTimers.current[timerKey]) {
      clearTimeout(pollTimers.current[timerKey]);
      delete pollTimers.current[timerKey];
    }

    setUpdates(prev => ({ ...prev, [app]: { app, status: 'updating' } }));
    try {
      const result = await triggerUpdate(app);
      setUpdates(prev => ({ ...prev, [app]: result }));
      if (result.status === 'updating') {
        pollUpdateStatus(app);
      }
    } catch (e) {
      setUpdates(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Update failed' },
      }));
    }
  }, [pollUpdateStatus]);

  const pollInstallStatus = useCallback((app: string) => {
    const timerKey = `install:${app}`;
    const poll = async () => {
      try {
        const result = await fetchInstallStatus(app);
        setInstalls(prev => ({ ...prev, [app]: result }));
        if (result.status === 'installing') {
          pollTimers.current[timerKey] = window.setTimeout(poll, 3000);
        } else {
          delete pollTimers.current[timerKey];
        }
      } catch {
        pollTimers.current[timerKey] = window.setTimeout(poll, 5000);
      }
    };
    poll();
  }, []);

  const startInstall = useCallback(async (app: string) => {
    setInstalls(prev => ({ ...prev, [app]: { app, status: 'installing', progress: 'Startar installation...' } }));
    try {
      triggerInstall(app).then(result => {
        setInstalls(prev => ({ ...prev, [app]: result }));
      }).catch(e => {
        setInstalls(prev => ({
          ...prev,
          [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
        }));
      });
      pollInstallStatus(app);
    } catch (e) {
      setInstalls(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
      }));
    }
  }, [pollInstallStatus]);

  const runServiceAction = useCallback(async (app: string, action: 'start' | 'stop' | 'restart') => {
    setActions(prev => ({ ...prev, [app]: { status: 'pending', action } }));
    try {
      const result = await serviceAction(app, action);
      setActions(prev => ({ ...prev, [app]: result }));
      const delay = result.status === 'error' ? 8000 : 3000;
      setTimeout(() => {
        setActions(prev => {
          const next = { ...prev };
          delete next[app];
          return next;
        });
      }, delay);
    } catch (e) {
      setActions(prev => ({
        ...prev,
        [app]: { app, action, status: 'error', message: e instanceof Error ? e.message : `${action} failed` },
      }));
    }
  }, []);

  useEffect(() => {
    return () => {
      Object.values(pollTimers.current).forEach(clearTimeout);
    };
  }, []);

  return { updates, startUpdate, installs, startInstall, actions, runServiceAction };
}
