import { useState, useCallback, useEffect, useRef } from 'react';
import { triggerUpdate, triggerInstall, fetchInstallStatus, type UpdateResult, type InstallResult } from '@/lib/api';

export function useServiceUpdate() {
  const [updates, setUpdates] = useState<Record<string, UpdateResult>>({});
  const [installs, setInstalls] = useState<Record<string, InstallResult>>({});
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
        // Keep polling on network errors during install
        pollTimers.current[app] = window.setTimeout(poll, 5000);
      }
    };
    poll();
  }, []);

  const startInstall = useCallback(async (app: string) => {
    setInstalls(prev => ({ ...prev, [app]: { app, status: 'installing', progress: 'Startar installation...' } }));
    try {
      // Fire and forget — the API starts the install in background
      triggerInstall(app).then(result => {
        setInstalls(prev => ({ ...prev, [app]: result }));
      }).catch(e => {
        setInstalls(prev => ({
          ...prev,
          [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
        }));
      });
      // Start polling for progress
      pollInstallStatus(app);
    } catch (e) {
      setInstalls(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
      }));
    }
  }, [pollInstallStatus]);

  useEffect(() => {
    return () => {
      Object.values(pollTimers.current).forEach(clearTimeout);
    };
  }, []);

  return { updates, startUpdate, installs, startInstall };
}
