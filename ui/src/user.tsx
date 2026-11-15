// The user's name, until logins exist (decision 6 of the write API, I5): typed
// in the header, kept in this browser, sent as X-User so the database can put
// it in the audit log. It identifies, it doesn't authenticate.
import { createContext, useContext, useState, type ReactNode } from "react";
import { setApiUser } from "./api/client";

const STORAGE_KEY = "accomm.user";

function readStored(): string {
  try {
    return localStorage.getItem(STORAGE_KEY) ?? "";
  } catch {
    return "";
  }
}

interface UserState {
  name: string;
  setName: (name: string) => void;
}

const UserContext = createContext<UserState | null>(null);

export function UserProvider({ children }: { children: ReactNode }) {
  const [name, setNameState] = useState(() => {
    const stored = readStored();
    setApiUser(stored);
    return stored;
  });
  const setName = (next: string) => {
    setNameState(next);
    setApiUser(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Storage blocked: the name lasts until the page is closed.
    }
  };
  return <UserContext.Provider value={{ name, setName }}>{children}</UserContext.Provider>;
}

export function useUser(): UserState {
  const state = useContext(UserContext);
  if (!state) throw new Error("useUser must be used inside UserProvider");
  return state;
}
