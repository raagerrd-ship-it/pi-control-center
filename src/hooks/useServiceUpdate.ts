import { useState, useCallback } from 'react';
import { triggerUpdate, type UpdateResult } from '@/lib/api';

export function useServiceUpdate() {
  const [updates, setUpdates] = useState<Record<string, UpdateResult>>({});

  const startUpdate = useCallback(async (app: string) => {
    setUpdates(prev => ({
      ...prev,
      [app]: { app, status: 'updating' },
    }));

    try {
      const result = await triggerUpdate(app);
      setUpdates(prev => ({ ...prev, [app]: result }));
    } catch (e) {
      setUpdates(prev => ({
        ...prev,
        [app]: {
          app,
          status: 'error',
          message: e instanceof Error ? e.message : 'Update failed',
        },
      }));
    }
  }, []);

  return { updates, startUpdate };
}
