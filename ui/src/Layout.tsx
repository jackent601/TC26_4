import { NavLink, Outlet } from "react-router";
import { useTenant } from "./tenant";

export function Layout() {
  const { tenants, code, setCode, isDemo, error } = useTenant();

  return (
    <div className="app">
      <header className="header">
        <span className="title">Accommodation</span>
        <nav className="nav">
          <NavLink to="/" end>
            Home
          </NavLink>
        </nav>
        <div className="tenant-switch" role="group" aria-label="Tenant">
          {tenants.map((t) => (
            <button
              key={t.code}
              type="button"
              aria-pressed={t.code === code}
              className={t.code === code ? "selected" : undefined}
              title={t.name}
              onClick={() => t.code && setCode(t.code)}
            >
              {t.code}
            </button>
          ))}
        </div>
      </header>

      {isDemo && (
        <div className="demo-banner" role="status">
          DEMO DATA: sample data only, and it can be reset at any time.
        </div>
      )}
      {error && <div className="error">Could not load tenants: {error.message}</div>}

      <main className="main">
        <Outlet />
      </main>
    </div>
  );
}
