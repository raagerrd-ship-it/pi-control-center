import { useState, useCallback, useEffect, useRef } from 'react';
import {
  triggerUpdate, fetchUpdateStatus,
  triggerInstall, fetchInstallStatus, fetchAvailableServices,
  serviceAction, triggerUninstall,
  type UpdateResult, type InstallResult, type ServiceActionResult, type UninstallResult,
} from '@/lib/api';
import { useActivityLog } from '@/hooks/useActivityLog';

export function useServiceUpdate(serviceNames: Record<string, string>) {
  const [updates, setUpdates] = useState<Record<string, UpdateResult>>({});
  const [installs, setInstalls] = useState<Record<string, InstallResult>>({});
  const [uninstalls, setUninstalls] = useState<Record<string, UninstallResult>>({});
  const [actions, setActions] = useState<Record<string, ServiceActionResult | { status: 'pending'; action: string }>>({});
  const pollTimers = useRef<Record<string, number>>({});
  const { addEntry } = useActivityLog();

  // Refs to avoid callback recreation when these change
  const addEntryRef = useRef(addEntry);
  addEntryRef.current = addEntry;
  const serviceNamesRef = useRef(serviceNames);
  serviceNamesRef.current = serviceNames;

  const label = (app: string) => (serviceNamesRef.current[app] || app).toUpperCase();

  const pollUpdateStatus = useCallback((app: string) => {
    const timerKey = `update:${app}`;
    let retryCount = 0;
    const poll = async () => {
      try {
        const result = await fetchUpdateStatus(app);
        if (retryCount > 2) {
          addEntryRef.current(label(app), 'Åter kontakt — fortsätter spåra uppdatering', 'success');
        }
        retryCount = 0;
        setUpdates(prev => ({ ...prev, [app]: result }));
        if (result.status === 'updating') {
          pollTimers.current[timerKey] = window.setTimeout(poll, 3000);
        } else {
          delete pollTimers.current[timerKey];
          if (result.status === 'success') addEntryRef.current(label(app), 'Uppdaterad', 'success');
          if (result.status === 'error') addEntryRef.current(label(app), 'Uppdatering misslyckades', 'error');
        }
      } catch {
        retryCount++;
        if (retryCount === 3) {
          addEntryRef.current(label(app), 'Pi upptagen — inväntar status...', 'info');
        } else if (retryCount % 20 === 0) {
          addEntryRef.current(label(app), `Fortfarande ingen status (försök ${retryCount})`, 'info');
        }
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
    addEntryRef.current(label(app), 'Uppdatering startad', 'info');
    setUpdates(prev => ({ ...prev, [app]: { app, status: 'updating' } }));
    try {
      const result = await triggerUpdate(app);
      setUpdates(prev => ({ ...prev, [app]: result }));
      if (result.status === 'updating') pollUpdateStatus(app);
      else if (result.status === 'success') addEntryRef.current(label(app), 'Uppdaterad', 'success');
      else if (result.status === 'error') addEntryRef.current(label(app), 'Uppdatering misslyckades', 'error');
    } catch (e) {
      addEntryRef.current(label(app), 'Uppdatering misslyckades', 'error');
      setUpdates(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Update failed' },
      }));
    }
  }, [pollUpdateStatus]);

  const pollInstallStatus = useCallback((app: string) => {
    const timerKey = `install:${app}`;
    let lastProgress = '';
    let retryCount = 0;
    const poll = async () => {
      try {
        const result = await fetchInstallStatus(app);
        if (retryCount > 2) {
          addEntryRef.current(label(app), 'Åter kontakt — fortsätter spåra installation', 'success');
        }
        retryCount = 0;
        setInstalls(prev => ({ ...prev, [app]: result }));
        if (result.status === 'installing') {
          const msg = result.progress || 'Installerar...';
          const elapsed = result.elapsed ? ` (${result.elapsed})` : '';
          const progressMsg = `${msg}${elapsed}`;
          if (progressMsg !== lastProgress) {
            lastProgress = progressMsg;
            addEntryRef.current(label(app), progressMsg, 'info');
          }
          pollTimers.current[timerKey] = window.setTimeout(poll, 3000);
        } else {
          delete pollTimers.current[timerKey];
          if (result.status === 'success') {
            addEntryRef.current(label(app), `Installerad${result.message ? ` — ${result.message}` : ''}`, 'success');
          }
          if (result.status === 'error') {
            addEntryRef.current(label(app), `Installation misslyckades: ${result.message || 'okänt fel'}`, 'error');
          }
        }
      } catch {
        retryCount++;
        if (retryCount === 3) {
          addEntryRef.current(label(app), 'Pi upptagen — inväntar status...', 'info');
        } else if (retryCount % 20 === 0) {
          addEntryRef.current(label(app), `Fortfarande ingen status (försök ${retryCount})`, 'info');
        }
        pollTimers.current[timerKey] = window.setTimeout(poll, 5000);
      }
    };
    poll();
  }, []);

  const startInstall = useCallback(async (app: string, port: number, core: number) => {
    addEntryRef.current(label(app), `Installation startad (port ${port}, core ${core})`, 'info');
    setInstalls(prev => ({ ...prev, [app]: { app, status: 'installing', progress: 'Startar installation...' } }));
    try {
      triggerInstall(app, port, core).then(result => {
        setInstalls(prev => ({ ...prev, [app]: result }));
      }).catch(e => {
        setInstalls(prev => ({
          ...prev,
          [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
        }));
      });
      // Small delay to let API write the initial status file
      setTimeout(() => pollInstallStatus(app), 2000);
    } catch (e) {
      addEntryRef.current(label(app), 'Installation misslyckades', 'error');
      setInstalls(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Install failed' },
      }));
    }
  }, [pollInstallStatus]);

  const startUninstall = useCallback(async (app: string) => {
    addEntryRef.current(label(app), 'Avinstallation startad', 'info');
    setUninstalls(prev => ({ ...prev, [app]: { app, status: 'success' } }));
    try {
      const result = await triggerUninstall(app);
      setUninstalls(prev => ({ ...prev, [app]: result }));
      if (result.status === 'success') addEntryRef.current(label(app), 'Avinstallerad', 'success');
      else addEntryRef.current(label(app), 'Avinstallation misslyckades', 'error');
    } catch (e) {
      addEntryRef.current(label(app), 'Avinstallation misslyckades', 'error');
      setUninstalls(prev => ({
        ...prev,
        [app]: { app, status: 'error', message: e instanceof Error ? e.message : 'Uninstall failed' },
      }));
    }
  }, []);

  const runServiceAction = useCallback(async (app: string, action: 'start' | 'stop' | 'restart') => {
    const actionLabel = action === 'start' ? 'Startar' : action === 'stop' ? 'Stoppar' : 'Startar om';
    addEntryRef.current(label(app), actionLabel + '...', 'info');
    setActions(prev => ({ ...prev, [app]: { status: 'pending', action } }));
    try {
      const result = await serviceAction(app, action);
      setActions(prev => ({ ...prev, [app]: result }));
      const doneLabel = action === 'start' ? 'Startad' : action === 'stop' ? 'Stoppad' : 'Omstartad';
      if (result.status === 'success') addEntryRef.current(label(app), doneLabel, 'success');
      else addEntryRef.current(label(app), `${doneLabel} misslyckades`, 'error');
      const delay = result.status === 'error' ? 8000 : 3000;
      setTimeout(() => {
        setActions(prev => {
          const next = { ...prev };
          delete next[app];
          return next;
        });
      }, delay);
    } catch (e) {
      addEntryRef.current(label(app), `${action} misslyckades`, 'error');
      setActions(prev => ({
        ...prev,
        [app]: { app, action, status: 'error', message: e instanceof Error ? e.message : `${action} failed` },
      }));
    }
  }, []);

  // On mount: check for any active installs or updates and resume polling
  useEffect(() => {
    const resumeActive = async () => {
      try {
        const services = await fetchAvailableServices();
        for (const svc of services) {
          try {
            const installResult = await fetchInstallStatus(svc.key);
            if (installResult.status === 'installing') {
              addEntryRef.current(label(svc.key), 'Återupptar spårning av pågående installation', 'info');
              setInstalls(prev => ({ ...prev, [svc.key]: installResult }));
              pollInstallStatus(svc.key);
            }
          } catch {}
          try {
            const updateResult = await fetchUpdateStatus(svc.key);
            if (updateResult.status === 'updating') {
              addEntryRef.current(label(svc.key), 'Återupptar spårning av pågående uppdatering', 'info');
              setUpdates(prev => ({ ...prev, [svc.key]: updateResult }));
              pollUpdateStatus(svc.key);
            }
          } catch {}
        }
        // Also check dashboard update
        try {
          const dashResult = await fetchUpdateStatus('dashboard');
          if (dashResult.status === 'updating') {
            addEntryRef.current('DASHBOARD', 'Återupptar spårning av pågående uppdatering', 'info');
            setUpdates(prev => ({ ...prev, dashboard: dashResult }));
            pollUpdateStatus('dashboard');
          }
        } catch {}
      } catch {}
    };
    resumeActive();

    return () => {
      Object.values(pollTimers.current).forEach(clearTimeout);
    };
  }, []);

  return { updates, startUpdate, installs, startInstall, uninstalls, startUninstall, actions, runServiceAction };
}
