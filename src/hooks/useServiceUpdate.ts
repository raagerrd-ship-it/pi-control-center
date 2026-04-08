import { useState, useCallback, useEffect, useRef } from 'react';
import { triggerUpdate, triggerInstall, fetchInstallStatus, serviceAction, type UpdateResult, type InstallResult, type ServiceActionResult } from '@/lib/api';

export function useServiceUpdate() {
  const [updates, setUpdates] = useState<Record<string, UpdateResult>>({});
  const [installs, setInstalls] = useState<Record<string, InstallResult>>({});
  const [actions, setActions] = useState<Record<string, ServiceActionResult | { status: 'pending'; action: string }>>({});
  const pollTimers = useRef<Record<string, number>>({});

  const startUpdate = useCallback(async (app: string) => {
    setUpdates(prev => ({ ...prev, [app]: { app, status: 'updating' } }));
    try {
      const result = await triggerUpdate(app);
      setUpdates(prev => ({ ...prev, [app]: result }));
    } catch (e) {
      setUpdates(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Update failed' },
      }));
    }
  }, []);

  const pollInstallStatus = useCallback((app: string) => {
    const poll = async () => {
      try {
        const result = await fetchInstallStatus(app);
        setInstalls(prev => ({ ...prev, [app]: result }));
        if (result.status === 'installing') {
          pollTimers.current[app] = window.setTimeout(poll, 3000);
        }
      } catch {
        pollTimers.current[app] = window.setTimeout(poll, 5000);
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
      // Auto-clear success after 3s, keep errors visible for 8s
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
