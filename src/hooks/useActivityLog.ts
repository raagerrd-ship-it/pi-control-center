import { createContext, useContext, useCallback, useState, type ReactNode } from 'react';
import React from 'react';

export interface ActivityEntry {
  time: string;
  source: string;
  message: string;
  type: 'info' | 'success' | 'error';
}

interface ActivityLogContextValue {
  entries: ActivityEntry[];
  addEntry: (source: string, message: string, type: ActivityEntry['type']) => void;
  clearLog: () => void;
}

const STORAGE_KEY = 'pi-dashboard-log';
const MAX_ENTRIES = 100;

function loadEntries(): ActivityEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.slice(-MAX_ENTRIES) : [];
  } catch {
    return [];
  }
}

const ActivityLogContext = createContext<ActivityLogContextValue | null>(null);

export function ActivityLogProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<ActivityEntry[]>(loadEntries);

  const addEntry = useCallback((source: string, message: string, type: ActivityEntry['type']) => {
    const time = new Date().toLocaleTimeString('sv-SE', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    setEntries(prev => {
      const next = [...prev.slice(-(MAX_ENTRIES - 1)), { time, source, message, type }];
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(next)); } catch {}
      return next;
    });
  }, []);

  const clearLog = useCallback(() => {
    setEntries([]);
    try { localStorage.removeItem(STORAGE_KEY); } catch {}
  }, []);

  return React.createElement(
    ActivityLogContext.Provider,
    { value: { entries, addEntry, clearLog } },
    children
  );
}

export function useActivityLog() {
  const ctx = useContext(ActivityLogContext);
  if (!ctx) throw new Error('useActivityLog must be used within ActivityLogProvider');
  return ctx;
}
