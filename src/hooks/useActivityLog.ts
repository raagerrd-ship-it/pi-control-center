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
}

const ActivityLogContext = createContext<ActivityLogContextValue | null>(null);

export function ActivityLogProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<ActivityEntry[]>([]);

  const addEntry = useCallback((source: string, message: string, type: ActivityEntry['type']) => {
    const time = new Date().toLocaleTimeString('sv-SE', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    setEntries(prev => [...prev.slice(-99), { time, source, message, type }]);
  }, []);

  return React.createElement(
    ActivityLogContext.Provider,
    { value: { entries, addEntry } },
    children
  );
}

export function useActivityLog() {
  const ctx = useContext(ActivityLogContext);
  if (!ctx) throw new Error('useActivityLog must be used within ActivityLogProvider');
  return ctx;
}
